import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { Agent } from "./agent.js";
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
import { Inbound, log, send } from "./protocol.js";
import {
  cardKind,
  classify,
  configureClassifier,
  replyTask,
  researchTask,
  resetClassifier,
  Trigger,
  warmClassifier,
} from "./trigger.js";

const HOME = homedir();
let config: AdvisorConfig = loadConfig();

/// The user's live session prompt: free-text context seeded at session_start
/// and editable mid-session (session_context messages). Injected per task via
/// sessionContextPrefix() — read fresh at dispatch — so edits take effect on
/// the next research/query/reply without rebuilding the persistent lanes.
let sessionContext = "";

const TOOLS = ["WebSearch", "WebFetch", "Read", "Grep", "Glob"];

/// Parallel research lanes: triggers fan out across persistent sessions.
/// Pool grows lazily up to maxLanes (settable from the app).
let maxLanes = 3;

interface Lane {
  name: string;
  session: Agent;
  busy: boolean;
  currentCardId?: string;
}

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
      cwd: HOME,
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

interface TranscriptEntry {
  id: string;
  // "me"/"them" are spoken lines; "note" is an editorial note the user injected
  // (issue #34), rendered with a distinct label in the delta windows.
  source: TranscriptSource;
  text: string;
  ts: number;
}

let transcript: TranscriptEntry[] = [];
// Each persistent session tracks which transcript entries it has already seen.
const cursors = new Map<string, number>();
let busy = false; // user queries (priority lane)
let cardCounter = 0;
let auto = true;
/// True between session_start and session_end. Gates the auto-classifier so a
/// classify already scheduled or in flight when the session ends can't enqueue
/// fresh research — which would stream cards into a closed/replaced session.
/// User queries (Ask box, right-click) are deliberately not gated by this.
let sessionActive = false;

/// Persistent sessions remember earlier messages, so send only new transcript.
function transcriptDelta(lane: string): string {
  const seen = cursors.get(lane) ?? 0;
  const fresh = transcript.slice(seen);
  cursors.set(lane, transcript.length);
  if (fresh.length === 0) return "";
  const text = fresh.map((e) => transcriptLine(e.source, e.text)).join("\n");
  return `Conversation since my last message:\n<transcript>\n${text}\n</transcript>\n\n`;
}

async function runCard(
  lane: Lane,
  kind: "answer" | "context" | "factcheck" | "query",
  title: string,
  task: string,
  triggerId?: string
): Promise<void> {
  const cardId = `c${++cardCounter}`;
  lane.currentCardId = cardId;
  send({ type: "card", id: cardId, trigger: triggerId, kind, title, body: "…", state: "pending" });
  try {
    const prompt = sessionContextPrefix(sessionContext) + transcriptDelta(lane.name) + task;
    const { text, error } = await lane.session.run(prompt, (body) => {
      if (!cancelledCards.has(cardId)) {
        send({ type: "card_update", id: cardId, body, state: "streaming" });
      }
    });
    if (!cancelledCards.has(cardId)) {
      const outcome = cardOutcome(text, error);
      send({ type: "card_update", id: cardId, body: outcome.body, state: outcome.state });
    }
  } catch (err) {
    log(`agent error: ${err}`);
    if (!cancelledCards.has(cardId)) {
      send({
        type: "card_update",
        id: cardId,
        body: `error: ${err instanceof Error ? err.message : String(err)}`,
        state: "failed",
      });
    }
  } finally {
    lane.currentCardId = undefined;
    cancelledCards.delete(cardId);
  }
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
    const { text, error } = await lane.session.run(task, (body) => {
      if (!cancelledCards.has(msg.cardId)) {
        send({ type: "card_update", id: msg.cardId, body: header + body, state: "streaming" });
      }
    });
    if (!cancelledCards.has(msg.cardId)) {
      const outcome = cardOutcome(text, error);
      send({
        type: "card_update",
        id: msg.cardId,
        body: header + outcome.body,
        state: outcome.state,
      });
    }
  } catch (err) {
    log(`reply error: ${err}`);
    if (!cancelledCards.has(msg.cardId)) {
      send({
        type: "card_update",
        id: msg.cardId,
        body: header + `error: ${err instanceof Error ? err.message : String(err)}`,
        state: "failed",
      });
    }
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

/// Run a one-shot task over a self-contained document (a saved transcript),
/// streaming the result back as document_answer on `id`. Shared by ask_document
/// (a question) and summarise_document (the Summarise button), which differ only
/// in the prompt.
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
  send({ type: "document_answer", id, body: "…", state: "pending" });
  try {
    const { text, error } = await lane.session.run(prompt, (body) =>
      send({ type: "document_answer", id, body, state: "streaming" })
    );
    const outcome = cardOutcome(text, error);
    send({ type: "document_answer", id, body: outcome.body, state: outcome.state });
  } catch (err) {
    log(`document task error: ${err}`);
    send({
      type: "document_answer",
      id,
      body: `error: ${err instanceof Error ? err.message : String(err)}`,
      state: "failed",
    });
  } finally {
    lane.session.reset(); // dispose the transient session
    activeDocQuestions--;
  }
}

function runDocumentQuestion(msg: Extract<Inbound, { type: "ask_document" }>): Promise<void> {
  return runDocumentTask(msg.id, documentQuestionTask(msg.question, msg.document));
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
  const cardId = msg.cardId ?? `c${++cardCounter}`;
  const lane = makeLane("summary");
  lane.currentCardId = cardId;
  summaryLanes.push(lane);
  if (reusing) {
    send({ type: "card_update", id: cardId, body: "…", state: "pending" });
  } else {
    send({ type: "card", id: cardId, kind: "summary", title: "Summary", body: "…", state: "pending" });
  }
  try {
    const { text, error } = await lane.session.run(summaryTask(msg.transcript), (body) => {
      if (!cancelledCards.has(cardId)) {
        send({ type: "card_update", id: cardId, body, state: "streaming" });
      }
    });
    if (!cancelledCards.has(cardId)) {
      const outcome = cardOutcome(text, error);
      send({ type: "card_update", id: cardId, body: outcome.body, state: outcome.state });
    }
  } catch (err) {
    log(`summarise error: ${err}`);
    if (!cancelledCards.has(cardId)) {
      send({
        type: "card_update",
        id: cardId,
        body: `error: ${err instanceof Error ? err.message : String(err)}`,
        state: "failed",
      });
    }
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
  const seen = cursors.get("classifier") ?? 0;
  const fresh = transcript.slice(seen);
  const end = transcript.length;
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
  debounceTimer = setTimeout(() => void runClassify(), DEBOUNCE_MS);
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
        cursors.set("classifier", end);
        classifyFailStreak = 0;
      } else {
        log(`classify failed (${Date.now() - ct0}ms, attempt ${classifyFailStreak}) — re-feeding window next pass`);
      }
      return;
    }
    classifyFailStreak = 0;
    // Success (including a genuine "found nothing"): commit the cursor past this
    // window so its lines are judged exactly once.
    cursors.set("classifier", end);
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
    void runCard(lane, cardKind(t.kind), t.subject, researchTask(t.kind, t.subject, t.query), t.anchorId).finally(() => {
      log(`research "${t.subject}" ${Date.now() - t0}ms`);
      lane.busy = false;
      drainResearch();
    });
  }
}

// MARK: protocol handling

function handle(msg: Inbound): void {
  switch (msg.type) {
    case "session_start":
      sessionActive = true;
      transcript = [];
      cursors.clear();
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
      void warmClassifier();
      void researchLanes[0]?.session.run("warm-up; reply READY", undefined, 15_000);
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
        ).finally(() => {
          busy = false;
        });
      } else {
        void runCard(queryLane, "query", msg.text, `Question: ${msg.text}`).finally(() => {
          busy = false;
        });
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
    case "cancel": {
      cancelledCards.add(msg.cardId);
      send({ type: "card_update", id: msg.cardId, body: "cancelled", state: "cancelled" });
      const lane = [...researchLanes, queryLane, ...replyLanes, ...summaryLanes].find(
        (l) => l.currentCardId === msg.cardId
      );
      if (lane) {
        log(`cancelling ${msg.cardId} on ${lane.name}`);
        void lane.session.interrupt();
      }
      break;
    }
    case "card_reply":
      // Transient session, parallel-safe — no busy gate, no pool slot.
      void runCardReply(msg);
      break;
    case "ask_document":
      // History-browser question about a saved transcript. Transient session,
      // parallel-safe — no busy gate, no pool slot, no live-session state.
      void runDocumentQuestion(msg);
      break;
    case "summarise_live":
      // Summarise the live session into its single summary card. Transient
      // session, parallel-safe — no busy gate, no pool slot.
      void runSummariseLive(msg);
      break;
    case "summarise_document":
      // Summarise a saved transcript (the history browser). Like ask_document:
      // transient session, parallel-safe, no live-session state.
      void runSummariseDocument(msg);
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
