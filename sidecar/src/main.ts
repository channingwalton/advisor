import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { AgentSession } from "./agent.js";
import { Inbound, log, send, Source } from "./protocol.js";
import { classify, resetClassifier, Trigger } from "./trigger.js";

const VAULT = `${homedir()}/Documents/Notes`;

const SYSTEM = `You are Advisor, a realtime meeting assistant running on Channing's Mac.
Each user message is a research task, usually with a snippet of live conversation
transcript. Respond concisely and usefully for someone mid-conversation:
- Lead with the answer; no preamble.
- Use WebSearch for facts about the world; use Read/Grep/Glob to search the
  Obsidian vault at ${VAULT} for personal/work context.
- Cite sources inline as markdown links or vault file paths.
- If you cannot verify something, say "couldn't verify" rather than guessing.
- NEVER ask the user questions — this is a one-shot answer with no way to
  reply. If the request is ambiguous, state your assumption in one line and
  answer under it. If context is missing, give the most useful answer you can
  with what you have.
- British spelling. Keep answers under ~150 words unless asked for depth.`;

const TOOLS = ["WebSearch", "WebFetch", "Read", "Grep", "Glob"];

/// Parallel research lanes: triggers fan out across persistent sessions.
/// Pool grows lazily up to maxLanes (settable from the app).
let maxLanes = 3;

interface Lane {
  name: string;
  session: AgentSession;
  busy: boolean;
  currentCardId?: string;
}

const cancelledCards = new Set<string>();

const researchLanes: Lane[] = [];

function ensureLanes(): void {
  while (researchLanes.length < maxLanes) {
    const name = `research${researchLanes.length}`;
    researchLanes.push({
      name,
      session: new AgentSession({
        name,
        systemPrompt: SYSTEM,
        allowedTools: TOOLS,
        cwd: VAULT,
        readRoots: [VAULT],
      }),
      busy: false,
    });
  }
}
ensureLanes();

const queryLane: Lane = {
  name: "query",
  session: new AgentSession({
    name: "query",
    systemPrompt: SYSTEM,
    allowedTools: TOOLS,
    cwd: VAULT,
    readRoots: [VAULT],
  }),
  busy: false,
};

interface TranscriptEntry {
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
let sessionCostUsd = 0;

function addCost(c: number): void {
  if (c <= 0) return;
  sessionCostUsd += c;
  send({ type: "usage", sessionCostUsd: Number(sessionCostUsd.toFixed(4)) });
}

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
  task: string
): Promise<void> {
  const cardId = `c${++cardCounter}`;
  lane.currentCardId = cardId;
  send({ type: "card", id: cardId, kind, title, body: "…", state: "pending" });
  try {
    const { text, costUsd } = await lane.session.run(transcriptDelta(lane.name) + task, (body) => {
      if (!cancelledCards.has(cardId)) {
        send({ type: "card_update", id: cardId, body, state: "streaming" });
      }
    });
    addCost(costUsd);
    if (!cancelledCards.has(cardId)) {
      send({
        type: "card_update",
        id: cardId,
        body: text || "no answer produced",
        state: text ? "done" : "failed",
      });
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

// MARK: auto-trigger pipeline

const DEBOUNCE_MS = 1500;
const COVERED_TTL_MS = 10 * 60 * 1000;

/// New-since-last-classify utterances, with consecutive same-source lines
/// merged so the classifier sees sentences, not STT fragments. The classifier
/// session is persistent, so it has already seen everything earlier — feeding
/// only the delta guarantees every line is judged exactly once.
function classifierDelta(): string {
  const seen = cursors.get("classifier") ?? 0;
  const fresh = transcript.slice(seen);
  cursors.set("classifier", transcript.length);
  if (fresh.length === 0) return "";
  const blocks: { source: Source; text: string }[] = [];
  for (const e of fresh) {
    const last = blocks[blocks.length - 1];
    if (last && last.source === e.source) {
      last.text += " " + e.text;
    } else {
      blocks.push({ source: e.source, text: e.text });
    }
  }
  return blocks.map((b) => `${b.source}: ${b.text}`).join("\n");
}

let debounceTimer: NodeJS.Timeout | undefined;
let classifying = false;
let rerunWanted = false;
const covered = new Map<string, number>();
const researchQueue: Trigger[] = [];

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
    const window = classifierDelta();
    if (!window) return;
    const { triggers, costUsd } = await classify(window, coveredSubjects());
    addCost(costUsd);
    log(`classify → ${triggers.length} trigger(s)`);
    for (const t of triggers) {
      const key = normalise(t.subject);
      if (!key || covered.has(key)) continue;
      covered.set(key, Date.now());
      log(`trigger(${t.kind}): ${t.subject}`);
      researchQueue.push(t);
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
    const kind = t.kind === "question" ? "answer" : t.kind;
    const task =
      t.kind === "question"
        ? `Answer this question from the conversation: ${t.query}`
        : t.kind === "factcheck"
          ? `Fact-check this claim from the conversation: "${t.query}". Give a verdict first (true / false / mixed / couldn't verify), then the evidence with sources.`
          : `Give brief, useful background on "${t.subject}" as it relates to the conversation: ${t.query}`;
    lane.busy = true;
    void runCard(lane, kind, t.subject, task).finally(() => {
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
      sessionCostUsd = 0;
      resetClassifier();
      for (const lane of researchLanes) lane.session.reset();
      queryLane.session.reset();
      log(`session ${msg.sessionId} started`);
      break;
    case "utterance":
      transcript.push({ source: msg.source, text: msg.text, ts: msg.ts });
      log(`utterance(${msg.source}): ${msg.text.slice(0, 60)}`);
      scheduleClassify();
      break;
    case "query":
      if (busy) {
        send({ type: "error", fatal: false, message: "already answering — wait for the current card" });
        return;
      }
      busy = true;
      void runCard(queryLane, "query", msg.text, `Question: ${msg.text}`).finally(() => {
        busy = false;
      });
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
      send({ type: "card_update", id: msg.cardId, body: "cancelled", state: "failed" });
      const lane = [...researchLanes, queryLane].find((l) => l.currentCardId === msg.cardId);
      if (lane) {
        log(`cancelling ${msg.cardId} on ${lane.name}`);
        void lane.session.interrupt();
      }
      break;
    }
    case "session_end":
      if (debounceTimer) clearTimeout(debounceTimer);
      log("session ended");
      break;
  }
}

send({ type: "hello", version: 1 });
log(`ready; vault=${VAULT}`);

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
