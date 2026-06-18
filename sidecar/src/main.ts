import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { Agent } from "./agent.js";
import { createAgent } from "./providers.js";
import { AdvisorConfig, loadConfig, modelArg } from "./config.js";
import { buildResearchSystem, documentQuestionTask, sessionContextPrefix } from "./prompts.js";
import { cardOutcome, boundedPush } from "./cards.js";
import { Inbound, log, send, Source } from "./protocol.js";
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
  source: Source;
  text: string;
  ts: number;
}

let transcript: TranscriptEntry[] = [];
// Each persistent session tracks which transcript entries it has already seen.
const cursors = new Map<string, number>();
let busy = false; // user queries (priority lane)
let cardCounter = 0;
let auto = true;

/// Persistent sessions remember earlier messages, so send only new transcript.
function transcriptDelta(lane: string): string {
  const seen = cursors.get(lane) ?? 0;
  const fresh = transcript.slice(seen);
  cursors.set(lane, transcript.length);
  if (fresh.length === 0) return "";
  const text = fresh.map((e) => `${e.source}: ${e.text}`).join("\n");
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
  send({ type: "card_update", id: msg.cardId, body: header + "…", state: "pending" });
  try {
    const task =
      sessionContextPrefix(sessionContext) +
      replyTask(msg.kind, msg.title, msg.base, msg.replyText, msg.transcript ?? "");
    const { text, error } = await lane.session.run(task, (body) => {
      send({ type: "card_update", id: msg.cardId, body: header + body, state: "streaming" });
    });
    const outcome = cardOutcome(text, error);
    send({ type: "card_update", id: msg.cardId, body: header + outcome.body, state: outcome.state });
  } catch (err) {
    log(`reply error: ${err}`);
    send({
      type: "card_update",
      id: msg.cardId,
      body: header + `error: ${err instanceof Error ? err.message : String(err)}`,
      state: "failed",
    });
  } finally {
    lane.session.reset(); // dispose the transient session
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

async function runDocumentQuestion(msg: Extract<Inbound, { type: "ask_document" }>): Promise<void> {
  if (activeDocQuestions >= MAX_CONCURRENT_DOC_QUESTIONS) {
    send({
      type: "document_answer",
      id: msg.id,
      body: "failed: too many questions in flight — wait for one to finish",
      state: "failed",
    });
    return;
  }
  activeDocQuestions++;
  const lane = makeLane("document");
  send({ type: "document_answer", id: msg.id, body: "…", state: "pending" });
  try {
    const { text, error } = await lane.session.run(
      documentQuestionTask(msg.question, msg.document),
      (body) => send({ type: "document_answer", id: msg.id, body, state: "streaming" })
    );
    const outcome = cardOutcome(text, error);
    send({ type: "document_answer", id: msg.id, body: outcome.body, state: outcome.state });
  } catch (err) {
    log(`document question error: ${err}`);
    send({
      type: "document_answer",
      id: msg.id,
      body: `error: ${err instanceof Error ? err.message : String(err)}`,
      state: "failed",
    });
  } finally {
    lane.session.reset(); // dispose the transient session
    activeDocQuestions--;
  }
}

// MARK: auto-trigger pipeline

const DEBOUNCE_MS = 1500;
const COVERED_TTL_MS = 10 * 60 * 1000;

/// New-since-last-classify utterances, with consecutive same-source lines
/// merged so the classifier sees sentences, not STT fragments. The classifier
/// session is persistent, so it has already seen everything earlier — feeding
/// only the delta guarantees every line is judged exactly once.
function classifierDelta(): { text: string; anchorId?: string } {
  const seen = cursors.get("classifier") ?? 0;
  const fresh = transcript.slice(seen);
  cursors.set("classifier", transcript.length);
  if (fresh.length === 0) return { text: "" };
  const blocks: { source: Source; text: string }[] = [];
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
    text: blocks.map((b) => `${b.source}: ${b.text}`).join("\n"),
    anchorId: fresh[fresh.length - 1].id,
  };
}

let debounceTimer: NodeJS.Timeout | undefined;
let classifying = false;
let rerunWanted = false;
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
  if (!auto) return;
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => void runClassify(), DEBOUNCE_MS);
}

async function runClassify(): Promise<void> {
  if (classifying) {
    rerunWanted = true;
    return;
  }
  classifying = true;
  try {
    const { text: window, anchorId } = classifierDelta();
    if (!window) return;
    log(`classify start (window ${window.length} chars)`);
    const ct0 = Date.now();
    const { triggers } = await classify(window, coveredSubjects());
    log(`classify ${Date.now() - ct0}ms → ${triggers.length} trigger(s)`);
    log(`classify → ${triggers.length} trigger(s)`);
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
      transcript = [];
      cursors.clear();
      covered.clear();
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
      const lane = [...researchLanes, queryLane].find((l) => l.currentCardId === msg.cardId);
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
    case "session_end":
      if (debounceTimer) clearTimeout(debounceTimer);
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
