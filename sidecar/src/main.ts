import { createInterface } from "node:readline";
import { createAgent } from "./providers.js";
import { AdvisorConfig, loadConfig } from "./config.js";
import {
  documentQuestionTask,
  sessionContextPrefix,
  summaryTask,
} from "./prompts.js";
import { ProcessCardIDs } from "./cardIds.js";
import { Inbound, log, logSync, send } from "./protocol.js";
import { handleCancel } from "./cancel.js";
import { cardUpdateFrame, guardedRun } from "./guardedRun.js";
import { cardLaneOptions, Lane, LanePool, runCard as runCardWith, Transcript, type RunCardDeps } from "./lanes.js";
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
// callback — would otherwise terminate the Node process (issue #45),
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
/// so a stray rejection surfaces as a diagnostic rather than tripping Node's
/// unhandledRejection process kill (issue #45). Returns a handler for `.catch`.
function guard(op: string): (err: unknown) => void {
  return (err) => log(`fire-and-forget ${op} rejected: ${err}`);
}

/// The user's live session prompt: free-text context seeded at session_start
/// and editable mid-session (session_context messages). Injected per task via
/// sessionContextPrefix() — read fresh at dispatch — so edits take effect on
/// the next research/query/reply without rebuilding the persistent lanes.
let sessionContext = "";

const cancelledCards = new Set<string>();

function makeLane(name: string): Lane {
  return {
    name,
    session: createAgent(config.provider, cardLaneOptions(config, name)),
    busy: false,
  };
}

const transcript = new Transcript();

/// Parallel research lanes: triggers fan out across persistent sessions. The
/// pool grows lazily to its size (settable from the app) and sheds excess lanes
/// as they go idle (LanePool); a shed lane's transcript cursor goes with it, so
/// a lane re-created under its name is sent the whole conversation.
const research = new LanePool(makeLane, 3, (lane) => transcript.forget(lane.name));

let queryLane: Lane = makeLane("query");

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
      lane.session, msg.cardId, task, cardUpdateFrame(msg.cardId, header),
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
      lane.session, cardId, summaryTask(msg.transcript), cardUpdateFrame(cardId),
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
  freeLane: () => research.free(),
  releaseLane: (lane) => research.release(lane),
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
      research.reset();
      queryLane.session.reset();
      queryLane = makeLane("query");
      // Warm the cold-spawn off the critical path: the first real question then
      // skips the SDK subprocess boot (~5-10s) on the classifier and lead
      // research lane. Best-effort, fire-and-forget; warm-up answers discarded.
      void warmClassifier().catch(guard("classifier warm-up"));
      void research.all[0]?.session
        .run("warm-up; reply READY", undefined, 15_000)
        .catch(guard("research warm-up"));
      log(`session ${msg.sessionId} started (sensitivity=${config.triggerSensitivity})`);
      break;
    case "utterance":
      transcript.push({ id: msg.id, source: msg.source, text: msg.text, ts: msg.ts });
      // Length, not text: the log is diagnostics, the transcript lives in the
      // user's session folder (code review 2026-10-17).
      log(`utterance(${msg.source}): ${msg.text.length} chars`);
      pipeline.heard();
      break;
    case "note":
      // An editorial note rides the same transcript stream the agents read, so
      // the classifier and every research/query lane pick it up via their delta.
      // Classify too: the user opted for notes to be able to trigger research.
      transcript.push({ id: msg.id, source: "note", text: msg.text, ts: msg.ts });
      log(`note: ${msg.text.length} chars`);
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
      if (typeof msg.lanes === "number" && Number.isFinite(msg.lanes)) {
        research.resize(Math.max(1, Math.min(8, Math.floor(msg.lanes))));
        log(`research lanes: ${research.size}`);
        pipeline.drain();
      }
      break;
    case "cancel":
      handleCancel(msg.cardId, {
        cancelledCards,
        cardLanes: [...research.all, queryLane, ...replyLanes, ...summaryLanes],
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
  // Neither failure logs the frame itself: an utterance's text is in it, and
  // the log holds no transcript text (code review 2026-10-17).
  let msg: Inbound;
  try {
    msg = JSON.parse(trimmed) as Inbound;
  } catch (err) {
    // The error's own message quotes the input, so only its name is logged.
    log(`bad message: not JSON, ${trimmed.length} chars (${err instanceof Error ? err.name : "error"})`);
    return;
  }
  try {
    handle(msg);
  } catch (err) {
    const type = typeof msg === "object" && msg !== null ? String((msg as { type?: unknown }).type) : typeof msg;
    // Our own error, capped: a thrown message could still quote the frame.
    const reason = err instanceof Error ? `${err.name}: ${err.message.split("\n")[0].slice(0, 160)}` : "error";
    log(`bad message (${type}): ${reason}`);
  }
});
// The shutdown contract with the app (SidecarManager.discardProcess): it closes
// our stdin and we exit at once, taking our CLI children with us. The app has
// already failed every in-flight card by then, so there is nothing to wait for
// (an idle wait used to sit here, unreachable: the app sent SIGTERM in the same
// instant — code review 2026-10-17). Every lane is reset first, which aborts
// its in-flight turn: the Codex SDK kills its CLI on abort and has no exit
// handler, so leaving without this would orphan a running `codex exec`; the
// Agent SDK kills its CLIs from Node's exit handlers as well, which a SIGTERM
// would skip. The exit is scheduled first and waits a tick, so the abort
// signals are dispatched and a reset that throws (swallowed by the
// uncaughtException keep-alive above) cannot keep the process here. The log
// line is written synchronously (`logSync`): an async pipe write would be
// dropped by the exit. The app's SIGTERM is the late backstop for a sidecar that fails to leave.
rl.on("close", () => {
  setImmediate(() => process.exit(0));
  logSync("stdin closed, exiting");
  for (const reset of [
    resetClassifier,
    ...[...research.all, queryLane, ...replyLanes, ...documentLanes, ...summaryLanes].map((l) => () => l.session.reset()),
  ]) {
    try {
      reset();
    } catch (err) {
      log(`reset on exit failed: ${err}`);
    }
  }
});
