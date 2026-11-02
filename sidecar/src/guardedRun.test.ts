import { test } from "node:test";
import assert from "node:assert/strict";
import { cardUpdateFrame, guardedRun, type GuardedRunDeps } from "./guardedRun.js";
import type { Outbound } from "./protocol.js";
import type { RunProgress, TaskResult } from "./agent.js";

// A session whose run() streams the given chunks then resolves with `result`.
function fakeSession(chunks: string[], result: TaskResult) {
  return {
    run: async (_task: string, progress?: RunProgress): Promise<TaskResult> => {
      let acc = "";
      for (const c of chunks) { acc += c; progress?.onText?.(acc); }
      return result;
    },
  };
}

function makeDeps(): GuardedRunDeps & { sent: Outbound[] } {
  const sent: Outbound[] = [];
  return { cancelledCards: new Set<string>(), send: (m) => sent.push(m), sent };
}

const cardFrame = (id: string) => cardUpdateFrame(id);

test("guardedRun streams then sends the terminal outcome (issue #66)", async () => {
  const deps = makeDeps();
  const result = await guardedRun(
    fakeSession(["a", "b"], { text: "ab" }), "c1", "task", cardFrame("c1"), "err", deps
  );
  assert.deepEqual(result, { text: "ab" });
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "a", state: "streaming" },
    // "ab" arrived within the interval, so the terminal frame carries it.
    { type: "card_update", id: "c1", body: "ab", state: "done" }, // cardOutcome
  ]);
});

test("guardedRun reports a failed turn and its state (issue #66)", async () => {
  const deps = makeDeps();
  const result = await guardedRun(
    fakeSession([], { text: "", error: "timed out" }), "c1", "task", cardFrame("c1"), "err", deps
  );
  assert.equal(result.error, "timed out");
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "failed: timed out", state: "failed" },
  ]);
});

// The cancel guard (issue #55/#66): once the id is cancelled mid-run, no further
// frame is sent, so the app's "cancelled" stands.
test("guardedRun suppresses sends for a cancelled card (issue #66)", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const deps = makeDeps();
  const session = {
    run: async (_task: string, progress?: RunProgress): Promise<TaskResult> => {
      progress?.onText?.("partial");       // arrives before cancel
      deps.cancelledCards.add("c1");       // user cancels mid-run
      progress?.onText?.("more");          // must be suppressed
      t.mock.timers.tick(1_000);           // even once its interval is up
      return { text: "final" };            // terminal must be suppressed too
    },
  };
  const result = await guardedRun(session, "c1", "task", cardFrame("c1"), "err", deps);
  assert.equal(result.error, undefined);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "partial", state: "streaming" },
  ]);
});

// A thrown run resolves as failed and reports the error through the frame.
test("guardedRun catches a thrown run and frames the error (issue #66)", async () => {
  const deps = makeDeps();
  const session = { run: async (): Promise<TaskResult> => { throw new Error("boom"); } };
  const result = await guardedRun(session, "c1", "task", cardFrame("c1"), "err", deps);
  assert.deepEqual(result, { text: "", error: "boom" });
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "error: boom", state: "failed" },
  ]);
});

// Token streaming calls onText for every few words; the app re-renders the
// card's markdown per frame, so frames are rate-limited, and the latest text
// still goes out once the interval is up.
test("#card-token-stream rapid text collapses into one frame per interval", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const deps = makeDeps();
  const session = {
    run: async (_task: string, progress?: RunProgress): Promise<TaskResult> => {
      progress?.onText?.("He");
      progress?.onText?.("Hello");
      progress?.onText?.("Hello wor");
      t.mock.timers.tick(150);   // the trailing frame
      t.mock.timers.tick(1_000); // then a quiet second
      progress?.onText?.("Hello world");
      return { text: "Hello world" };
    },
  };
  await guardedRun(session, "c1", "task", cardFrame("c1"), "err", deps);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "He", state: "streaming" },
    { type: "card_update", id: "c1", body: "Hello wor", state: "streaming" },
    { type: "card_update", id: "c1", body: "Hello world", state: "streaming" },
    { type: "card_update", id: "c1", body: "Hello world", state: "done" },
  ]);
});

// A trailing frame due after the run ends must not land after the terminal one
// and reopen the card.
test("#card-token-stream no streaming frame follows the terminal frame", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const deps = makeDeps();
  await guardedRun(
    fakeSession(["a", "b", "c"], { text: "abc" }), "c1", "task", cardFrame("c1"), "err", deps
  );
  t.mock.timers.tick(1_000);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "a", state: "streaming" },
    { type: "card_update", id: "c1", body: "abc", state: "done" },
  ]);
});

// Before any text the card is still pending, but shows what the agent is doing;
// the first text replaces the activity line.
test("#card-activity activity shows on the pending card until text arrives", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "Date"] });
  const deps = makeDeps();
  const session = {
    run: async (_task: string, progress?: RunProgress): Promise<TaskResult> => {
      progress?.onActivity?.("Searching the web for “Cedar”");
      t.mock.timers.tick(1_000);
      progress?.onText?.("Cedar is");
      t.mock.timers.tick(1_000);
      progress?.onActivity?.("Reading example.com");
      t.mock.timers.tick(1_000);
      return { text: "Cedar is a migration." };
    },
  };
  await guardedRun(session, "c1", "task", cardFrame("c1"), "err", deps);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "…", state: "pending", activity: "Searching the web for “Cedar”" },
    { type: "card_update", id: "c1", body: "Cedar is", state: "streaming" },
    { type: "card_update", id: "c1", body: "Cedar is", state: "streaming", activity: "Reading example.com" },
    { type: "card_update", id: "c1", body: "Cedar is a migration.", state: "done" },
  ]);
});

// A follow-up's frames carry the thread so far; the activity rides alongside.
test("#card-activity a card frame keeps its prefix and carries the activity", () => {
  assert.deepEqual(cardUpdateFrame("c1", "base\n\n")("…", "pending", "Thinking…"), {
    type: "card_update", id: "c1", body: "base\n\n…", state: "pending", activity: "Thinking…",
  });
  assert.deepEqual(cardUpdateFrame("c1")("done text", "done"), {
    type: "card_update", id: "c1", body: "done text", state: "done",
  });
});
