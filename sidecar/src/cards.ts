/// Small pure helpers shared by the card pipeline. Kept out of main.ts so they
/// can be unit-tested without triggering its stdio side effects.

/// Terminal card body + state from a run result: prefer the answer, else show
/// the failure reason rather than a bare "no answer produced". An answer cut
/// short (it streams word by word, so it may stop mid-sentence) says so.
export function cardOutcome(text: string, error?: string): { body: string; state: "done" | "failed" } {
  if (text && error) return { body: `${text}\n\n*Stopped early: ${error}.*`, state: "done" };
  if (text) return { body: text, state: "done" };
  return { body: error ? `failed: ${error}` : "no answer produced", state: "failed" };
}

/// Push onto a capped FIFO, evicting the oldest entries when over `max`.
/// Mutates `queue` and returns the evicted items (newest is kept — it is the
/// most relevant to surface). `max` must be >= 1.
export function boundedPush<T>(queue: T[], item: T, max: number): T[] {
  queue.push(item);
  const dropped: T[] = [];
  while (queue.length > max) {
    const d = queue.shift();
    if (d !== undefined) dropped.push(d);
  }
  return dropped;
}
