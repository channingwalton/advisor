import { createInterface } from "node:readline";
import { createAgent } from "./providers.js";
import { AdvisorConfig, loadConfig, modelArg } from "./config.js";
import {
  buildResearchSystem,
  documentQuestionTask,
  sessionContextPrefix,
  summaryTask,
} from "./prompts.js";
import { ProcessCardIDs } from "./cardIds.js";
import { Inbound, log, send } from "./protocol.js";
import { handleCancel } from "./cancel.js";
import { guardedRun } from "./guardedRun.js";
import { Lane, runCard as runCardWith, Transcript, type RunCardDeps } from "./lanes.js";
import { AutoPipeline } from "./autoPipeline.js";
import {
  cardKind,
  classify,
  configureClassifier,
  documentResearchTask,
  replyTask,
  researchKind,
  researchTask,
  resetClassifier,
  warmClassifier,
} from "./trigger.js";

let config: AdvisorConfig = loadConfig();

// A fire-and-forget promise that rejects — or a stray synchronous throw in a
// callback — would otherwise terminate the process on Node 22 (issue #45),
// dropping the stdio pipe mid-session with no diagnostic for the app. We keep
// the sidecar alive and log instead, so a lone stray rejection can't kill a
// live session. The handlers must never throw (that would re-trigger the same
// path), so the log() call is itself guarded.
process.on("unhandledRejection", (reason) => {
  try {
    log(`unhandledRejection (kept alive): ${reason instanceof Error ? (reason.stack ?? reason.message) : reason}`);
  } catch {
    /* stderr unavailable — nothing safe left to do */
  }
});
// uncaughtException is swallowed too, deliberately. Exiting here reproduces the
// exact symptom #45 targets (silent pipe close, no diagnostic), whereas the
// dominant failure mode is a stray callback throw — recoverable, not global
// corruption: lanes are independent and session_start resets all state. Staying
// up keeps the rest of the session working; we log the full stack so a genuinely
// corrupt state is still diagnosable from the app's logs.
process.on("uncaughtException", (err) => {
  try {
    log(`uncaughtException (kept alive): ${err instanceof Error ? (err.stack ?? err.message) : err}`);
  } catch {
    /* stderr unavailable — nothing safe left to do */
  }
});

/// Guard a fire-and-forget promise: log its rejection tagged with the operation
/// so a stray rejection surfaces as a diagnostic rather than tripping Node 22's
/// unhandledRejection process kill (issue #45). Returns a handler for `.catch`.
function guard(op: string): (err: unknown) => void {
  return (err) => log(`fire-and-forget ${op} rejected: ${err}`);
}

/// The user's live session prompt: free-text context seeded at session_start
/// and editable mid-session (session_context messages). Injected per task via
/// sessionContextPrefix() — read fresh at dispatch — so edits take effect on
/// the next research/query/reply without rebuilding the persistent lanes.
let sessionContext = "";

const TOOLS = ["WebSearch", "WebFetch", "Read", "Grep", "Glob"];

/// Parallel research lanes: triggers fan out across persistent sessions.
/// Pool grows lazily up to maxLanes (settable from the app).
let maxLanes = 3;

const cancelledCards = new Set<string>();

const researchLanes: Lane[] = [];

function makeLane(name: string): Lane {
  return {
    name,
    session: createAgent(config.provider, {
      name,
      systemPrompt: buildResearchSystem(),
      model: modelArg(config),
      allowedTools: TOOLS,
      allowMcpActions: config.allowMcpActions,
    }),
    busy: false,
  };
}

function ensureLanes(): void {
  while (researchLanes.length < maxLanes) {
    researchLanes.push(makeLane(`research${researchLanes.length}`));
  }
}
ensureLanes();

let queryLane: Lane = makeLane("query");

const transcript = new Transcript();
let busy = false; // user queries (priority lane)
const cardIDs = new ProcessCardIDs();

const cardDeps: RunCardDeps = {
  transcript,
  nextCardId: () => cardIDs.next(),
  sessionContext: () => sessionContext,
  cancelledCards,
  send,
};

function runCard(
  lane: Lane,
  kind: "answer" | "context" | "factcheck" | "query",
  title: string,
  task: string,
  triggerId?: string
): Promise<void> {
  return runCardWith(lane, kind, title, task, triggerId, cardDeps);
}

/// Answer a follow-up typed into an existing card. Runs on a transient one-shot
/// session created and disposed here, so it never consumes a research-pool lane
/// (the pool stays free for new triggers) and carries no cross-card state. The
/// app supplies the card's current body and a transcript slice; we reproduce the
/// prefix the app already shows so the streamed body stays consistent.
/// Each reply spawns a fresh SDK subprocess; cap concurrent ones so a burst of
/// taps can't fork unbounded processes.
const MAX_CONCURRENT_REPLIES = 3;
let activeReplies = 0;
/// In-flight reply lanes, keyed by the card they answer, so a `cancel` can find
/// and interrupt them — they live outside the research pool and queryLane.
const replyLanes: Lane[] = [];

async function runCardReply(msg: Extract<Inbound, { type: "card_reply" }>): Promise<void> {
  const header = `${msg.base}\n\n---\n\n**You:** ${msg.replyText}\n\n`;
  if (activeReplies >= MAX_CONCURRENT_REPLIES) {
    send({
      type: "card_update",
      id: msg.cardId,
      body: header + "failed: too many replies in flight — wait for one to finish",
      state: "failed",
    });
    return;
  }
  activeReplies++;
  const lane = makeLane("reply");
  lane.currentCardId = msg.cardId;
  replyLanes.push(lane);
  send({ type: "card_update", id: msg.cardId, body: header + "…", state: "pending" });
  try {
    const task =
      sessionContextPrefix(sessionContext) +
      replyTask(msg.kind, msg.title, msg.base, msg.replyText, msg.transcript ?? "");
    await guardedRun(
      lane.session, msg.cardId, task,
      (body, state) => ({ type: "card_update", id: msg.cardId, body: header + body, state }),
      "reply error", { cancelledCards, send }
    );
  } finally {
    lane.session.reset(); // dispose the transient session
    lane.currentCardId = undefined;
    const i = replyLanes.indexOf(lane);
    if (i >= 0) replyLanes.splice(i, 1);
    cancelledCards.delete(msg.cardId);
    activeReplies--;
  }
}

/// Answer a question about a saved past transcript (the history browser). Like
/// runCardReply this runs on a transient one-shot session — no research-pool
/// slot, no live-session state (the document is the whole context) — so it's
/// parallel-safe and works mid-session. Streamed back as document_answer on the
/// request id. Cap concurrent ones so a burst can't fork unbounded subprocesses.
const MAX_CONCURRENT_DOC_QUESTIONS = 2;
let activeDocQuestions = 0;
/// In-flight document lanes (history-browser ask/summarise), keyed via
/// currentCardId (the request id) so a `cancel` can find and interrupt them.
/// Transient, outside the research pool — like reply/summary lanes.
const documentLanes: Lane[] = [];

/// Run a one-shot task over a self-contained document (a saved transcript),
/// streaming the result back as document_answer on `id`. Shared by ask_document
/// (a question) and summarise_document (the Summarise button), which differ only
/// in the prompt. Cancel-aware like runCardReply: a `cancel` for `id` interrupts
/// the run and suppresses the remaining sends so the app's "cancelled" stands.
async function runDocumentTask(id: string, prompt: string): Promise<void> {
  if (activeDocQuestions >= MAX_CONCURRENT_DOC_QUESTIONS) {
    send({
      type: "document_answer",
      id,
      body: "failed: too many questions in flight — wait for one to finish",
      state: "failed",
    });
    return;
  }
  activeDocQuestions++;
  const lane = makeLane("document");
  lane.currentCardId = id;
  documentLanes.push(lane);
  send({ type: "document_answer", id, body: "…", state: "pending" });
  try {
    await guardedRun(
      lane.session, id, prompt,
      (body, state) => ({ type: "document_answer", id, body, state }),
      "document task error", { cancelledCards, send }
    );
  } finally {
    lane.session.reset(); // dispose the transient session
    const i = documentLanes.indexOf(lane);
    if (i >= 0) documentLanes.splice(i, 1);
    cancelledCards.delete(id);
    activeDocQuestions--;
  }
}

function runDocumentQuestion(msg: Extract<Inbound, { type: "ask_document" }>): Promise<void> {
  return runDocumentTask(msg.id, documentQuestionTask(msg.question, msg.document));
}

async function runResearchDocument(msg: Extract<Inbound, { type: "research_document" }>): Promise<void> {
  const kind = researchKind(msg.action);
  if (!kind) {
    send({ type: "document_answer", id: msg.id, body: `failed: unknown action ${msg.action}`, state: "failed" });
    return;
  }
  return runDocumentTask(msg.id, documentResearchTask(kind, msg.text, msg.document));
}

function runReplyDocument(msg: Extract<Inbound, { type: "reply_document" }>): Promise<void> {
  return runDocumentTask(
    msg.id, replyTask(msg.kind, msg.title, msg.base, msg.replyText, msg.document, { saved: true })
  );
}

function runSummariseDocument(
  msg: Extract<Inbound, { type: "summarise_document" }>
): Promise<void> {
  return runDocumentTask(msg.id, summaryTask(msg.transcript));
}

/// In-flight summary lanes (the live Summarise button), keyed via currentCardId
/// so a `cancel` can find and interrupt them. Transient, outside the research
/// pool — like reply/document lanes.
const summaryLanes: Lane[] = [];

/// Summarise the live session into a single "summary" card. The first call opens
/// a new card; a re-summarise passes the existing card id and updates it in place
/// (card_update), so there is only ever one summary card per session.
async function runSummariseLive(msg: Extract<Inbound, { type: "summarise_live" }>): Promise<void> {
  const reusing = msg.cardId !== undefined;
  const cardId = msg.cardId ?? cardIDs.next();
  const lane = makeLane("summary");
  lane.currentCardId = cardId;
  summaryLanes.push(lane);
  if (reusing) {
    send({ type: "card_update", id: cardId, body: "…", state: "pending" });
  } else {
    send({ type: "card", id: cardId, kind: "summary", title: "Summary", body: "…", state: "pending" });
  }
  try {
    await guardedRun(
      lane.session, cardId, summaryTask(msg.transcript),
      (body, state) => ({ type: "card_update", id: cardId, body, state }),
      "summarise error", { cancelledCards, send }
    );
  } finally {
    lane.session.reset(); // dispose the transient session
    lane.currentCardId = undefined;
    const i = summaryLanes.indexOf(lane);
    if (i >= 0) summaryLanes.splice(i, 1);
    cancelledCards.delete(cardId);
  }
}

// MARK: auto-trigger pipeline

const pipeline = new AutoPipeline({
  transcript,
  classify,
  freeLane: () => {
    ensureLanes();
    // Only dispatch to the first maxLanes lanes (shrinking takes effect as lanes finish).
    return researchLanes.slice(0, maxLanes).find((l) => !l.busy);
  },
  research: (lane, t) =>
    runCard(lane, cardKind(t.kind), t.subject, researchTask(t.kind, t.subject, t.query), t.anchorId),
});

// MARK: protocol handling

function handle(msg: Inbound): void {
  switch (msg.type) {
    case "session_start":
      transcript.clear();
      pipeline.start();
      // Seed the live session prompt; the app may update it mid-session.
      sessionContext = msg.context ?? "";
      // Re-read preferences and rebuild sessions so prompt/model changes apply.
      config = loadConfig();
      configureClassifier(config);
      resetClassifier();
      for (const lane of researchLanes) lane.session.reset();
      researchLanes.length = 0;
      ensureLanes();
      queryLane.session.reset();
      queryLane = makeLane("query");
      // Warm the cold-spawn off the critical path: the first real question then
      // skips the SDK subprocess boot (~5-10s) on the classifier and lead
      // research lane. Best-effort, fire-and-forget; warm-up answers discarded.
      void warmClassifier().catch(guard("classifier warm-up"));
      void researchLanes[0]?.session
        .run("warm-up; reply READY", undefined, 15_000)
        .catch(guard("research warm-up"));
      log(`session ${msg.sessionId} started (sensitivity=${config.triggerSensitivity})`);
      break;
    case "utterance":
      transcript.push({ id: msg.id, source: msg.source, text: msg.text, ts: msg.ts });
      log(`utterance(${msg.source}): ${msg.text.slice(0, 60)}`);
      pipeline.heard();
      break;
    case "note":
      // An editorial note rides the same transcript stream the agents read, so
      // the classifier and every research/query lane pick it up via their delta.
      // Classify too: the user opted for notes to be able to trigger research.
      transcript.push({ id: msg.id, source: "note", text: msg.text, ts: msg.ts });
      log(`note: ${msg.text.slice(0, 60)}`);
      pipeline.heard();
      break;
    case "query":
      if (busy) {
        send({ type: "error", fatal: false, message: "already answering — wait for the current card" });
        return;
      }
      busy = true;
      if (msg.action) {
        // Right-click action on selected text: route to the same kind/template
        // as the auto-pipeline, anchored under the clicked utterance.
        const kind = msg.action === "answer" ? "question" : msg.action;
        void runCard(
          queryLane,
          msg.action,
          msg.text,
          researchTask(kind, msg.text, msg.text),
          msg.triggerId
        )
          .finally(() => {
            busy = false;
          })
          .catch(guard("query action"));
      } else {
        void runCard(queryLane, "query", msg.text, `Question: ${msg.text}`)
          .finally(() => {
            busy = false;
          })
          .catch(guard("query"));
      }
      break;
    case "session_context":
      // Live edit of the session prompt; applied to the next dispatched task.
      sessionContext = msg.text;
      log(`session prompt updated (${sessionContext.trim().length} chars)`);
      break;
    case "config":
      if (typeof msg.auto === "boolean") {
        pipeline.setAuto(msg.auto);
        log(`auto triggers: ${msg.auto}`);
      }
      if (typeof msg.lanes === "number") {
        maxLanes = Math.max(1, Math.min(8, Math.floor(msg.lanes)));
        log(`research lanes: ${maxLanes}`);
        pipeline.drain();
      }
      break;
    case "cancel":
      handleCancel(msg.cardId, {
        cancelledCards,
        cardLanes: [...researchLanes, queryLane, ...replyLanes, ...summaryLanes],
        documentLanes,
        send,
      });
      break;
    case "card_reply":
      // Transient session, parallel-safe — no busy gate, no pool slot.
      void runCardReply(msg).catch(guard("card_reply"));
      break;
    case "ask_document":
      // History-browser question about a saved transcript. Transient session,
      // parallel-safe — no busy gate, no pool slot, no live-session state.
      void runDocumentQuestion(msg).catch(guard("ask_document"));
      break;
    case "research_document":
      // Right-click research on a saved transcript (the Sessions browser). Like
      // ask_document: transient session, parallel-safe, no live-session state.
      void runResearchDocument(msg).catch(guard("research_document"));
      break;
    case "reply_document":
      // Follow-up on a saved card (the Sessions browser). Like ask_document:
      // transient session, parallel-safe, no live-session state.
      void runReplyDocument(msg).catch(guard("reply_document"));
      break;
    case "summarise_live":
      // Summarise the live session into its single summary card. Transient
      // session, parallel-safe — no busy gate, no pool slot.
      void runSummariseLive(msg).catch(guard("summarise_live"));
      break;
    case "summarise_document":
      // Summarise a saved transcript (the history browser). Like ask_document:
      // transient session, parallel-safe, no live-session state.
      void runSummariseDocument(msg).catch(guard("summarise_document"));
      break;
    case "session_end":
      pipeline.end();
      log("session ended");
      break;
  }
}

send({ type: "hello", version: 1 });
log(`ready; sensitivity=${config.triggerSensitivity}`);

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  try {
    handle(JSON.parse(trimmed) as Inbound);
  } catch (err) {
    log(`bad message: ${trimmed} (${err})`);
  }
});
rl.on("close", () => {
  const exitWhenIdle = () => {
    if (!busy && researchLanes.every((l) => !l.busy)) process.exit(0);
    setTimeout(exitWhenIdle, 200);
  };
  log("stdin closed, exiting when idle");
  exitWhenIdle();
});
