import { test } from "node:test";
import assert from "node:assert/strict";
import { guardedRun, type GuardedRunDeps } from "./guardedRun.js";
import type { Outbound, CardState } from "./protocol.js";
import type { TaskResult } from "./agent.js";

// A session whose run() streams the given chunks then resolves with `result`.
function fakeSession(chunks: string[], result: TaskResult) {
  return {
    run: async (_task: string, onText?: (acc: string) => void): Promise<TaskResult> => {
      let acc = "";
      for (const c of chunks) { acc += c; onText?.(acc); }
      return result;
    },
  };
}

function makeDeps(): GuardedRunDeps & { sent: Outbound[] } {
  const sent: Outbound[] = [];
  return { cancelledCards: new Set<string>(), send: (m) => sent.push(m), sent };
}

const cardFrame = (id: string) =>
  (body: string, state: CardState): Outbound => ({ type: "card_update", id, body, state });

test("guardedRun streams then sends the terminal outcome (issue #66)", async () => {
  const deps = makeDeps();
  const failed = await guardedRun(
    fakeSession(["a", "b"], { text: "ab" }), "c1", "task", cardFrame("c1"), "err", deps
  );
  assert.equal(failed, false);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "a", state: "streaming" },
    { type: "card_update", id: "c1", body: "ab", state: "streaming" },
    { type: "card_update", id: "c1", body: "ab", state: "done" }, // cardOutcome
  ]);
});

test("guardedRun reports a failed turn and its state (issue #66)", async () => {
  const deps = makeDeps();
  const failed = await guardedRun(
    fakeSession([], { text: "", error: "timed out" }), "c1", "task", cardFrame("c1"), "err", deps
  );
  assert.equal(failed, true);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "failed: timed out", state: "failed" },
  ]);
});

// The cancel guard (issue #55/#66): once the id is cancelled mid-run, no further
// frame is sent, so the app's "cancelled" stands.
test("guardedRun suppresses sends for a cancelled card (issue #66)", async () => {
  const deps = makeDeps();
  const session = {
    run: async (_task: string, onText?: (acc: string) => void): Promise<TaskResult> => {
      onText?.("partial");                 // arrives before cancel
      deps.cancelledCards.add("c1");       // user cancels mid-run
      onText?.("more");                    // must be suppressed
      return { text: "final" };            // terminal must be suppressed too
    },
  };
  const failed = await guardedRun(session, "c1", "task", cardFrame("c1"), "err", deps);
  assert.equal(failed, false);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "partial", state: "streaming" },
  ]);
});

// A thrown run resolves as failed and reports the error through the frame.
test("guardedRun catches a thrown run and frames the error (issue #66)", async () => {
  const deps = makeDeps();
  const session = { run: async (): Promise<TaskResult> => { throw new Error("boom"); } };
  const failed = await guardedRun(session, "c1", "task", cardFrame("c1"), "err", deps);
  assert.equal(failed, true);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "error: boom", state: "failed" },
  ]);
});
