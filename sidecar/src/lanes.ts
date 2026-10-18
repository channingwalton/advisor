import { Agent, type AgentSessionOptions } from "./agent.js";
import { AdvisorConfig, effortArg, modelArg } from "./config.js";
import { cardUpdateFrame, guardedRun } from "./guardedRun.js";
import { buildResearchSystem, sessionContextPrefix, transcriptLine, TranscriptSource } from "./prompts.js";
import { log, Outbound } from "./protocol.js";

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
      lane.session, cardId, prompt, cardUpdateFrame(cardId), "agent error", deps
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

/// The research pool: persistent lanes, `research0…`, grown to a size the app
/// can change mid-session (at a session start up front, so the first can be
/// warmed; otherwise on demand). Shrinking used to leave the lanes
/// beyond the new size alive — never dispatched to, but each holding a warm
/// CLI subprocess — until the next session start (code review 2026-10-17). Now
/// an excess lane is reset (its session and CLI gone) as soon as it is idle:
/// at the resize for idle ones, at `release()` for one that was mid-card.
/// `shed` runs for every lane that goes, so its owner can forget the lane's
/// transcript cursor: a lane re-created later under the same name is a fresh
/// session that has seen nothing. A `reset()` (session start) that catches a
/// lane mid-card aborts its session at once but retires the lane rather than
/// forgetting it: it stays in `all`, where `cancel` and the exit path look, and
/// keeps its name — which keys a transcript cursor its card's failure path will
/// still forget — until the card is over (#86).
export class LanePool {
  private lanes: Lane[] = [];
  /// Dropped by reset() mid-card; listed, and their names taken, until release().
  private retired: Lane[] = [];

  constructor(
    private readonly make: (name: string) => Lane,
    private max: number,
    private readonly shed: (lane: Lane) => void = () => {}
  ) {}

  /// Every lane, including excess and retired ones still finishing a card. The
  /// pool proper leads, so `all[0]` is a live lane.
  get all(): readonly Lane[] {
    return [...this.lanes, ...this.retired];
  }

  get size(): number {
    return this.max;
  }

  /// Change the pool size; grows on the next `free()`, shrinks now as far as
  /// the excess lanes are idle.
  resize(n: number): void {
    this.max = n;
    this.trim();
  }

  /// An idle lane within the pool size, growing the pool if it is short.
  free(): Lane | undefined {
    this.trim();
    while (this.lanes.length < this.max) this.lanes.push(this.make(this.nextName()));
    // Bounded by size, not by trim having run: an excess lane still finishing
    // its card sits past the size and is never dispatched to.
    return this.lanes.slice(0, this.max).find((l) => !l.busy);
  }

  /// The lowest `research<n>` not in use. Names key the transcript cursors, so
  /// a shrink that sheds `research1` while `research2` finishes its card must
  /// not let the next grow mint a second `research2` — nor a reset() re-mint a
  /// retired lane's name.
  private nextName(): string {
    const taken = new Set(this.all.map((l) => l.name));
    for (let i = 0; ; i++) {
      if (!taken.has(`research${i}`)) return `research${i}`;
    }
  }

  /// A lane's card is done. An excess lane leaves now rather than at the next
  /// dispatch — in a quiet conversation there may be none. A retired lane
  /// (its session already dropped by reset()) is delisted and its name freed.
  release(lane: Lane): void {
    lane.busy = false;
    if (this.lanes.includes(lane)) this.trim();
    else this.retired = this.retired.filter((l) => l !== lane);
  }

  /// A new session: every lane's session dropped, the pool rebuilt to size.
  /// A lane mid-card is retired, not forgotten (see the class note).
  reset(): void {
    for (const lane of this.lanes) {
      if (lane.busy) this.retired.push(lane);
      // A drop that throws must not stop the others, or leave this lane listed
      // twice: the loop always completes and the pool is always rebuilt.
      try {
        this.drop(lane);
      } catch (err) {
        log(`${lane.name}: reset failed: ${err}`);
      }
    }
    this.lanes = [];
    this.free();
  }

  private trim(): void {
    const keep = this.lanes.slice(0, this.max);
    for (const lane of this.lanes.slice(this.max)) {
      if (lane.busy) keep.push(lane); // leaves at release()
      else this.drop(lane);
    }
    this.lanes = keep;
  }

  private drop(lane: Lane): void {
    lane.session.reset();
    this.shed(lane);
  }
}
