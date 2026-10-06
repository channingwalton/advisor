import { createInterface } from "node:readline";
import { createAgent } from "./providers.js";
import { AdvisorConfig, loadConfig, modelArg } from "./config.js";
import {
  buildResearchSystem,
  documentQuestionTask,
  sessionContextPrefix,
  summaryTask,
  transcriptLine,
  TranscriptSource,
} from "./prompts.js";
import { cardOutcome, boundedPush } from "./cards.js";
import { ProcessCardIDs } from "./cardIds.js";
import { Inbound, log, send } from "./protocol.js";
import { handleCancel } from "./cancel.js";
import { guardedRun } from "./guardedRun.js";
import { Lane, runCard as runCardWith, Transcript, type RunCardDeps } from "./lanes.js";
import {
  cardKind,
  classify,
  configureClassifier,
  documentResearchTask,
  replyTask,
  researchKind,
  researchTask,
  resetClassifier,
  Trigger,
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
let auto = true;
/// True between session_start and session_end. Gates the auto-classifier so a
/// classify already scheduled or in flight when the session ends can't enqueue
/// fresh research — which would stream cards into a closed/replaced session.
/// User queries (Ask box, right-click) are deliberately not gated by this.
let sessionActive = false;

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

const DEBOUNCE_MS = 1500;
const COVERED_TTL_MS = 10 * 60 * 1000;

/// New-since-last-classify utterances, with consecutive same-source lines
/// merged so the classifier sees sentences, not STT fragments. The classifier
/// session is persistent, so it has already seen everything earlier — feeding
/// only the delta means each line is judged once on a successful classify.
///
/// This does NOT advance the classifier cursor — it returns `end` (the window's
/// exclusive upper bound) and lets runClassify commit it only after a successful
/// classify. On a failed/timed-out classify the cursor stays put so the window
/// is re-fed next pass rather than skipped (issue #43). Because classify is
/// serialised (the `classifying` guard), no second delta runs during the await,
/// so deferring the commit can neither double-feed nor skip lines.
function classifierDelta(): { text: string; anchorId?: string; end: number } {
  const fresh = transcript.entries.slice(transcript.cursor("classifier"));
  const end = transcript.entries.length;
  if (fresh.length === 0) return { text: "", end };
  const blocks: { source: TranscriptSource; text: string }[] = [];
  for (const e of fresh) {
    const last = blocks[blocks.length - 1];
    if (last && last.source === e.source) {
      last.text += " " + e.text;
    } else {
      blocks.push({ source: e.source, text: e.text });
    }
  }
  // Anchor every trigger from this pass to the last line of the window — the
  // sentence that completed it. Removes research-latency drift; residual error
  // is at most the debounce window.
  return {
    text: blocks.map((b) => transcriptLine(b.source, b.text)).join("\n"),
    anchorId: fresh[fresh.length - 1].id,
    end,
  };
}

let debounceTimer: NodeJS.Timeout | undefined;
let classifying = false;
let rerunWanted = false;
/// Consecutive classify failures (timeout / dead session / unparseable output).
/// On failure the classifier cursor is NOT advanced, so the window is re-fed on
/// the next pass. Bounded: after MAX_CLASSIFY_RETRIES straight failures we give
/// up on that window and advance anyway, so a persistently failing classifier
/// can't stall the pipeline or grow the re-fed window without bound.
const MAX_CLASSIFY_RETRIES = 3;
let classifyFailStreak = 0;
const covered = new Map<string, number>();
const researchQueue: Trigger[] = [];

/// Cap the backlog so a long, noisy session can't grow it without bound.
const MAX_RESEARCH_QUEUE = 20;
function enqueueResearch(item: Trigger): void {
  for (const dropped of boundedPush(researchQueue, item, MAX_RESEARCH_QUEUE)) {
    log(`research queue full — dropped oldest: ${dropped.subject}`);
  }
}

function normalise(subject: string): string {
  return subject.toLowerCase().replace(/[^a-z0-9 ]/g, "").trim();
}

function coveredSubjects(): string[] {
  const now = Date.now();
  for (const [k, t] of covered) {
    if (now - t > COVERED_TTL_MS) covered.delete(k);
  }
  return [...covered.keys()];
}

function scheduleClassify(): void {
  if (!auto || !sessionActive) return;
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => void runClassify().catch(guard("classify")), DEBOUNCE_MS);
}

async function runClassify(): Promise<void> {
  if (!sessionActive) return;
  if (classifying) {
    rerunWanted = true;
    return;
  }
  classifying = true;
  try {
    const { text: window, anchorId, end } = classifierDelta();
    if (!window) return;
    log(`classify start (window ${window.length} chars)`);
    const ct0 = Date.now();
    const result = await classify(window, coveredSubjects());
    if (!result.ok) {
      // Failed to classify (timeout / dead session / unparseable). Leave the
      // cursor un-advanced so this window is re-fed next pass instead of being
      // silently dropped (issue #43). Bounded: after MAX_CLASSIFY_RETRIES
      // straight failures, give up and advance past it so a persistently
      // failing classifier can't stall the pipeline or grow the window forever.
      if (++classifyFailStreak >= MAX_CLASSIFY_RETRIES) {
        log(`classify failed ${classifyFailStreak}x — giving up on this window, advancing cursor`);
        transcript.setCursor("classifier", end);
        classifyFailStreak = 0;
      } else {
        log(`classify failed (${Date.now() - ct0}ms, attempt ${classifyFailStreak}) — re-feeding window next pass`);
      }
      return;
    }
    classifyFailStreak = 0;
    // Success (including a genuine "found nothing"): commit the cursor past this
    // window so its lines are judged exactly once.
    transcript.setCursor("classifier", end);
    const { triggers } = result;
    log(`classify ${Date.now() - ct0}ms → ${triggers.length} trigger(s)`);
    // The session may have ended during the classify await — drop its triggers
    // so no research is enqueued for a session that's gone.
    if (!sessionActive) return;
    for (const t of triggers) {
      const key = normalise(t.subject);
      if (!key || covered.has(key)) continue;
      covered.set(key, Date.now());
      log(`trigger(${t.kind}): ${t.subject}`);
      enqueueResearch({ ...t, anchorId });
    }
    drainResearch();
  } finally {
    classifying = false;
    if (rerunWanted) {
      rerunWanted = false;
      scheduleClassify();
    }
  }
}

function drainResearch(): void {
  ensureLanes();
  while (researchQueue.length > 0) {
    // Only dispatch to the first maxLanes lanes (shrinking takes effect as lanes finish).
    const lane = researchLanes.slice(0, maxLanes).find((l) => !l.busy);
    if (!lane) return; // a lane finishing will call drainResearch again
    const t = researchQueue.shift()!;
    lane.busy = true;
    const t0 = Date.now();
    void runCard(lane, cardKind(t.kind), t.subject, researchTask(t.kind, t.subject, t.query), t.anchorId)
      .finally(() => {
        log(`research "${t.subject}" ${Date.now() - t0}ms`);
        lane.busy = false;
        drainResearch();
      })
      .catch(guard(`research "${t.subject}"`));
  }
}

// MARK: protocol handling

function handle(msg: Inbound): void {
  switch (msg.type) {
    case "session_start":
      sessionActive = true;
      transcript.clear();
      covered.clear();
      classifyFailStreak = 0;
      researchQueue.length = 0;
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
      scheduleClassify();
      break;
    case "note":
      // An editorial note rides the same transcript stream the agents read, so
      // the classifier and every research/query lane pick it up via their delta.
      // Classify too: the user opted for notes to be able to trigger research.
      transcript.push({ id: msg.id, source: "note", text: msg.text, ts: msg.ts });
      log(`note: ${msg.text.slice(0, 60)}`);
      scheduleClassify();
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
        auto = msg.auto;
        log(`auto triggers: ${auto}`);
      }
      if (typeof msg.lanes === "number") {
        maxLanes = Math.max(1, Math.min(8, Math.floor(msg.lanes)));
        log(`research lanes: ${maxLanes}`);
        drainResearch();
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
      // End the auto-pipeline: stop scheduling/accepting classifies and drop any
      // queued-but-not-yet-dispatched research. In-flight research lanes keep
      // running (the app's close prompt waits for or cancels those).
      sessionActive = false;
      if (debounceTimer) clearTimeout(debounceTimer);
      researchQueue.length = 0;
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
