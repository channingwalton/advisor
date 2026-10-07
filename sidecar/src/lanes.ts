import { Agent, type AgentSessionOptions } from "./agent.js";
import { AdvisorConfig, effortArg, modelArg } from "./config.js";
import { guardedRun } from "./guardedRun.js";
import { buildResearchSystem, sessionContextPrefix, transcriptLine, TranscriptSource } from "./prompts.js";
import { Outbound } from "./protocol.js";

const CARD_TOOLS = ["WebSearch", "WebFetch", "Read", "Grep", "Glob"];

/// The session options for a card lane — research, query, reply, document or
/// summary. The classifier is built separately and takes no effort setting.
export function cardLaneOptions(config: AdvisorConfig, name: string): AgentSessionOptions {
  return {
    name,
    systemPrompt: buildResearchSystem(),
    model: modelArg(config),
    effort: effortArg(config),
    allowedTools: CARD_TOOLS,
    allowMcpActions: config.allowMcpActions,
  };
}

/// A session that answers cards. Research/query lanes are pooled and persist
/// (warm) across cards; reply/summary/document lanes are transient.
export interface Lane {
  name: string;
  session: Agent;
  busy: boolean;
  currentCardId?: string;
}

export interface TranscriptEntry {
  id: string;
  // "me"/"them" are spoken lines; "note" is an editorial note the user injected
  // (issue #34), rendered with a distinct label in the delta windows.
  source: TranscriptSource;
  text: string;
  ts: number;
}

/// The live conversation, and how much of it each persistent session has
/// already been sent. Persistent sessions remember earlier messages, so each
/// task carries only the entries its session hasn't seen.
export class Transcript {
  private items: TranscriptEntry[] = [];
  private readonly cursors = new Map<string, number>();

  get entries(): readonly TranscriptEntry[] {
    return this.items;
  }

  push(entry: TranscriptEntry): void {
    this.items.push(entry);
  }

  /// A new session: no conversation, nothing sent.
  clear(): void {
    this.items = [];
    this.cursors.clear();
  }

  /// How many entries `reader` has been sent (or has committed, for readers
  /// that advance only on success, like the classifier).
  cursor(reader: string): number {
    return this.cursors.get(reader) ?? 0;
  }

  setCursor(reader: string, end: number): void {
    this.cursors.set(reader, end);
  }

  /// `reader`'s session was dropped: its next delta carries the whole conversation.
  forget(reader: string): void {
    this.cursors.delete(reader);
  }

  /// The entries past `reader`'s cursor, and the end index to commit once read.
  unseen(reader: string): { fresh: readonly TranscriptEntry[]; end: number } {
    return { fresh: this.items.slice(this.cursor(reader)), end: this.items.length };
  }

  /// The entries `lane` hasn't been sent, framed for its prompt, marking them sent.
  delta(lane: string): string {
    const { fresh, end } = this.unseen(lane);
    this.cursors.set(lane, end);
    if (fresh.length === 0) return "";
    const text = fresh.map((e) => transcriptLine(e.source, e.text)).join("\n");
    return `Conversation since my last message:\n<transcript>\n${text}\n</transcript>\n\n`;
  }
}

/// What runCard needs from the sidecar. Injected so it is testable without the
/// module-global stdout `send` (the same shape as guardedRun's deps).
export interface RunCardDeps {
  transcript: Transcript;
  nextCardId(): string;
  /// The live session prompt, read fresh at dispatch.
  sessionContext(): string;
  cancelledCards: Set<string>;
  send(msg: Outbound): void;
}

/// Answer one card on a pooled lane: open the card, run the task with the
/// conversation the lane hasn't seen, and stream the answer into the card.
export async function runCard(
  lane: Lane,
  kind: "answer" | "context" | "factcheck" | "query",
  title: string,
  task: string,
  triggerId: string | undefined,
  deps: RunCardDeps
): Promise<void> {
  const cardId = deps.nextCardId();
  lane.currentCardId = cardId;
  deps.send({ type: "card", id: cardId, trigger: triggerId, kind, title, body: "…", state: "pending" });
  let failed = false;
  try {
    const prompt = sessionContextPrefix(deps.sessionContext()) + deps.transcript.delta(lane.name) + task;
    failed = await guardedRun(
      lane.session, cardId, prompt,
      (body, state) => ({ type: "card_update", id: cardId, body, state }),
      "agent error", deps
    );
  } finally {
    // Recycle a pooled (research/query) lane after any failure — timeout/error.
    // Unlike the transient reply/summary/document lanes (disposed every turn),
    // these persist to keep their session warm; but a timed-out turn may have
    // wedged (interrupt is best-effort), so without this every later trigger
    // routed to this lane would burn a full timeout indefinitely (issue #46).
    // reset() drops the session; the lane's next card re-spawns it clean. For
    // research lanes, this runs before AutoPipeline.drain's `.finally` clears
    // `lane.busy`, so the re-dispatch always sees a fresh session. The warm session is kept on
    // the success path (failed === false). The fresh session has seen none of
    // the conversation, so forget the lane's cursor: its next card replays it all.
    if (failed) {
      lane.session.reset();
      deps.transcript.forget(lane.name);
    }
    lane.currentCardId = undefined;
    deps.cancelledCards.delete(cardId);
  }
}
