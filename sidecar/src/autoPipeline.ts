import { boundedPush } from "./cards.js";
import { Lane, Transcript, type TranscriptEntry } from "./lanes.js";
import { transcriptLine, TranscriptSource } from "./prompts.js";
import { log } from "./protocol.js";
import { ClassifyResult, Trigger } from "./trigger.js";

/// Quiet time after the last transcript line before classifying.
const DEBOUNCE_MS = 1500;
const COVERED_TTL_MS = 10 * 60 * 1000;
/// Consecutive classify failures (timeout / dead session / unparseable output).
/// On failure the classifier cursor is NOT advanced, so the window is re-fed on
/// the next pass. Bounded: after MAX_CLASSIFY_RETRIES straight failures we give
/// up on that window and advance anyway, so a persistently failing classifier
/// can't stall the pipeline or grow the re-fed window without bound.
const MAX_CLASSIFY_RETRIES = 3;
/// Cap the backlog so a long, noisy session can't grow it without bound.
const MAX_RESEARCH_QUEUE = 20;
/// How much of the conversation before the window a classifier session that
/// starts again gets, in characters of speech: about the last ten minutes. A
/// bound, not the whole meeting, because each failed Codex classify drops its
/// thread, and the pass gates every automatic card (#116).
export const CLASSIFIER_RECAP_CHARS = 8_000;

/// What the pipeline needs from the sidecar. Injected so the pipeline is
/// testable without the SDK or the module-global lanes.
export interface AutoPipelineDeps {
  transcript: Transcript;
  /// `earlier` is the end of the conversation before `window`. The classifier
  /// sends it only on a pass that starts a new session or thread (#116).
  /// `context` is the session prompt at this pass.
  classify(window: string, covered: string[], earlier: string, context: string): Promise<ClassifyResult>;
  /// The live session prompt. Default: none.
  sessionContext?(): string;
  /// A free research lane, or undefined when every lane is busy (a lane
  /// finishing drains the queue again).
  freeLane(): Lane | undefined;
  /// A research lane's card is done. Default: mark it idle. The pool uses this
  /// to shed an excess lane the moment it finishes, not at the next dispatch.
  releaseLane?(lane: Lane): void;
  /// Research one trigger as a card on `lane`, calling `textSent` when the
  /// card's first text goes to the app.
  research(lane: Lane, trigger: Trigger, textSent: () => void): Promise<void>;
  /// Overrides DEBOUNCE_MS (tests).
  debounceMs?: number;
  /// Where diagnostics go. Default: the sidecar log (tests capture them).
  log?(line: string): void;
  /// The clock, in ms. Default: Date.now (tests drive it by hand).
  now?(): number;
}

/// A trigger waiting for a lane, with when the line that completed its window
/// was heard.
type Queued = Trigger & { heardAt: number };

/// The automatic cards: classify new transcript after a pause, dedupe the
/// triggers against recently covered subjects, and research each on a free lane.
export class AutoPipeline {
  private auto = true;
  /// True between session_start and session_end. Gates the classifier so a
  /// classify already scheduled or in flight when the session ends can't enqueue
  /// fresh research — which would stream cards into a closed/replaced session.
  /// User queries (Ask box, right-click) are deliberately not gated by this.
  private sessionActive = false;
  private debounceTimer?: NodeJS.Timeout;
  private classifying = false;
  private rerunWanted = false;
  private classifyFailStreak = 0;
  private readonly covered = new Map<string, number>();
  private readonly queue: Queued[] = [];
  /// Bumped whenever Auto cards is toggled or a session starts or ends, so a
  /// classify that began under different conditions drops its result.
  private epoch = 0;
  /// When the newest transcript line arrived. Each line is pushed and heard in
  /// one step, so at classify time this is when the window's last line came.
  private lastHeardAt = 0;

  /// One writer of `lane.busy` on the way back: the deps' releaseLane, else idle.
  private readonly releaseLane: (lane: Lane) => void;
  private readonly log: (line: string) => void;
  private readonly now: () => number;

  constructor(private readonly deps: AutoPipelineDeps) {
    this.releaseLane = deps.releaseLane?.bind(deps) ?? ((lane) => { lane.busy = false; });
    this.log = deps.log?.bind(deps) ?? log;
    this.now = deps.now?.bind(deps) ?? Date.now;
  }

  /// A new session: nothing covered or queued.
  start(): void {
    this.epoch += 1;
    this.sessionActive = true;
    this.covered.clear();
    this.classifyFailStreak = 0;
    this.queue.length = 0;
  }

  /// End the pipeline: stop scheduling/accepting classifies and drop any
  /// queued-but-not-yet-dispatched research. In-flight research lanes keep
  /// running (the app's close prompt waits for or cancels those).
  end(): void {
    this.epoch += 1;
    this.sessionActive = false;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.queue.length = 0;
  }

  /// New transcript (an utterance or note): classify once it goes quiet.
  heard(): void {
    this.lastHeardAt = this.now();
    this.schedule();
  }

  /// Classify once the transcript goes quiet.
  private schedule(): void {
    if (!this.auto || !this.sessionActive) return;
    if (this.debounceTimer) clearTimeout(this.debounceTimer);
    this.debounceTimer = setTimeout(
      () => void this.runClassify().catch((err) => this.log(`fire-and-forget classify rejected: ${err}`)),
      this.deps.debounceMs ?? DEBOUNCE_MS
    );
  }

  /// The Auto cards toggle. Off stops automatic cards at once: the classify
  /// waiting out the pause, research waiting for a lane, and the result of a
  /// classify already running are all dropped (cards already researching
  /// finish). On again classifies only what is said from then on — not the
  /// stretch spoken while it was off.
  setAuto(on: boolean): void {
    if (on === this.auto) return;
    this.auto = on;
    this.epoch += 1;
    if (on) {
      this.deps.transcript.setCursor("classifier", this.deps.transcript.entries.length);
      this.classifyFailStreak = 0;
    } else {
      if (this.debounceTimer) clearTimeout(this.debounceTimer);
      this.debounceTimer = undefined;
      // Dropped research was never done, so its subjects aren't covered.
      for (const t of this.queue.splice(0)) this.covered.delete(normalise(t.subject));
      this.rerunWanted = false;
    }
  }

  /// Dispatch queued research to free lanes.
  drain(): void {
    while (this.queue.length > 0) {
      const lane = this.deps.freeLane();
      if (!lane) return; // a lane finishing will drain again
      const t = this.queue.shift()!;
      lane.busy = true;
      const t0 = this.now();
      // The card appears now: research opens it at once, pending.
      const textSent = () =>
        this.log(`card "${t.subject}" shown ${t0 - t.heardAt}ms, text ${this.now() - t.heardAt}ms after the last line`);
      void this.deps.research(lane, t, textSent)
        .finally(() => {
          this.log(`research "${t.subject}" ${this.now() - t0}ms`);
          this.releaseLane(lane);
          this.drain();
        })
        .catch((err) => this.log(`fire-and-forget research "${t.subject}" rejected: ${err}`));
    }
  }

  /// New-since-last-classify utterances, with consecutive same-source lines
  /// merged so the classifier sees sentences, not STT fragments. The classifier
  /// session is persistent, so it has already seen everything earlier (unless it
  /// started again: see classifierRecap) — feeding only the delta means each
  /// line is judged once on a successful classify.
  ///
  /// This does NOT advance the classifier cursor — it returns `end` (the window's
  /// exclusive upper bound) and lets runClassify commit it only after a successful
  /// classify. On a failed/timed-out classify the cursor stays put so the window
  /// is re-fed next pass rather than skipped (issue #43). Because classify is
  /// serialised (the `classifying` guard), no second delta runs during the await,
  /// so deferring the commit can neither double-feed nor skip lines.
  private classifierDelta(): { text: string; anchorId?: string; end: number } {
    const { fresh, end } = this.deps.transcript.unseen("classifier");
    if (fresh.length === 0) return { text: "", end };
    // Anchor every trigger from this pass to the last line of the window — the
    // sentence that completed it. Removes research-latency drift; residual error
    // is at most the debounce window.
    return { text: mergedLines(fresh), anchorId: fresh[fresh.length - 1].id, end };
  }

  /// The conversation before the classifier cursor, merged as the window is,
  /// and cut at a line to its last CLASSIFIER_RECAP_CHARS characters. The
  /// count includes the speaker labels and the line breaks of the merge (#125).
  /// The classifier session holds these lines until it starts again: a failed
  /// Codex classify drops its thread, and the next run recycles a wedged
  /// Claude turn (#46). The session sends them only on the pass that starts
  /// again, so a line such as "who owns it?" keeps its referent (#116). They
  /// are context, not new lines: the cursor stays, and the classifier does not
  /// judge them again.
  private classifierRecap(): string {
    const { entries } = this.deps.transcript;
    const tail: TranscriptEntry[] = [];
    let size = 0;
    for (let i = this.deps.transcript.cursor("classifier") - 1; i >= 0; i--) {
      const e = entries[i];
      const newer = tail[tail.length - 1];
      // What the line adds to the merged text: a space when it joins the block
      // of the line after it, else its label, and a line break before that block.
      const cost = e.text.length + (newer?.source === e.source ? 1 : labelLength(e.source) + (newer ? 1 : 0));
      if (size + cost > CLASSIFIER_RECAP_CHARS) {
        // A single line longer than the bound keeps its end, after its label and "…".
        if (!newer) tail.push({ ...e, text: "…" + e.text.slice(-(CLASSIFIER_RECAP_CHARS - labelLength(e.source) - 1)) });
        break;
      }
      size += cost;
      tail.push(e);
    }
    return mergedLines(tail.reverse());
  }

  private coveredSubjects(): string[] {
    const now = this.now();
    for (const [k, t] of this.covered) {
      if (now - t > COVERED_TTL_MS) this.covered.delete(k);
    }
    return [...this.covered.keys()];
  }

  private enqueue(item: Queued): void {
    for (const dropped of boundedPush(this.queue, item, MAX_RESEARCH_QUEUE)) {
      this.log(`research queue full — dropped oldest: ${dropped.subject}`);
      this.covered.delete(normalise(dropped.subject)); // never researched
    }
  }

  private async runClassify(): Promise<void> {
    if (!this.auto || !this.sessionActive) return;
    if (this.classifying) {
      this.rerunWanted = true;
      return;
    }
    this.classifying = true;
    try {
      const { text: window, anchorId, end } = this.classifierDelta();
      if (!window) return;
      const heardAt = this.lastHeardAt;
      this.log(`classify start (window ${window.length} chars)`);
      const ct0 = this.now();
      const epoch = this.epoch;
      const result = await this.deps.classify(
        window,
        this.coveredSubjects(),
        this.classifierRecap(),
        this.deps.sessionContext?.() ?? ""
      );
      // Auto cards was toggled, or the session ended or restarted, meanwhile:
      // drop the result and leave the cursor to the new conditions.
      if (epoch !== this.epoch) return;
      if (!result.ok) {
        // Failed to classify (timeout / dead session / unparseable). Leave the
        // cursor un-advanced so this window is re-fed next pass instead of being
        // silently dropped (issue #43). Bounded: after MAX_CLASSIFY_RETRIES
        // straight failures, give up and advance past it so a persistently
        // failing classifier can't stall the pipeline or grow the window forever.
        if (++this.classifyFailStreak >= MAX_CLASSIFY_RETRIES) {
          this.log(`classify failed ${this.classifyFailStreak}x — giving up on this window, advancing cursor`);
          this.deps.transcript.setCursor("classifier", end);
          this.classifyFailStreak = 0;
        } else {
          this.log(`classify failed (${this.now() - ct0}ms, attempt ${this.classifyFailStreak}) — re-feeding window next pass`);
        }
        return;
      }
      this.classifyFailStreak = 0;
      // Success (including a genuine "found nothing"): commit the cursor past this
      // window so its lines are judged exactly once.
      this.deps.transcript.setCursor("classifier", end);
      const { triggers } = result;
      const decidedAt = this.now();
      this.log(
        `classify ${decidedAt - ct0}ms → ${triggers.length} trigger(s), decided ${decidedAt - heardAt}ms after the last line`
      );
      for (const t of triggers) {
        const key = normalise(t.subject);
        if (!key || this.covered.has(key)) continue;
        this.covered.set(key, this.now());
        this.log(`trigger(${t.kind}): ${t.subject}`);
        this.enqueue({ ...t, anchorId, heardAt });
      }
      this.drain();
    } finally {
      this.classifying = false;
      if (this.rerunWanted) {
        this.rerunWanted = false;
        this.schedule();
      }
    }
  }
}

/// The length of the speaker label of a merged block, such as "them: ".
function labelLength(source: TranscriptSource): number {
  return transcriptLine(source, "").length;
}

/// Transcript lines with consecutive same-source lines merged, so the
/// classifier sees sentences, not STT fragments.
function mergedLines(entries: readonly TranscriptEntry[]): string {
  const blocks: { source: TranscriptSource; text: string }[] = [];
  for (const e of entries) {
    const last = blocks[blocks.length - 1];
    if (last && last.source === e.source) {
      last.text += " " + e.text;
    } else {
      blocks.push({ source: e.source, text: e.text });
    }
  }
  return blocks.map((b) => transcriptLine(b.source, b.text)).join("\n");
}

/// The dedup key for a subject, in any script: letters, marks and digits of
/// every alphabet survive (an ASCII-only filter emptied 東京 or Ελλάδα, and an
/// empty key is skipped — no card), punctuation goes, and only what is certainly
/// the same word is folded: case (Turkish İ as I first, or it lower-cases to i
/// plus a dot) and whitespace. Marks are kept — año/ano, мой/мои and
/// がっこう/かっこう are different words — and ß is not ss (Maße/Masse), because a
/// wrong merge silently loses a card while a missed one only duplicates it (and
/// the classifier's covered list catches many). NFC, not NFKC: compatibility
/// folding would make ½ and 12 one key.
function normalise(subject: string): string {
  return subject
    .normalize("NFC")
    .replace(/\u0130/g, "I")
    .toLowerCase()
    .replace(/[^\p{L}\p{M}\p{N}\s]/gu, "")
    .replace(/\s+/g, " ")
    .trim();
}
