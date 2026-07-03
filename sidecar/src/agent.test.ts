import { test } from "node:test";
import assert from "node:assert/strict";
import { AgentSession, AsyncQueue, type QueryFn } from "./agent.js";

// A controllable fake of the SDK's `query()` stream: an async-iterable of
// messages the test pushes into `messages`, plus an `interrupt()` spy. Each call
// to the returned queryFn records a fresh spawn, so a test can assert whether the
// session recycled (a new spawn) or reused a warm one, and drive each generation
// independently. Injecting this exercises the full run/timeout/reset lifecycle
// without spawning a real SDK subprocess (see issue #46).
interface FakeSpawn {
  messages: AsyncQueue<unknown>;
  interrupted: boolean;
}

function makeFakeQuery(): { queryFn: QueryFn; spawns: FakeSpawn[] } {
  const spawns: FakeSpawn[] = [];
  const queryFn = (() => {
    const messages = new AsyncQueue<unknown>();
    const rec: FakeSpawn = { messages, interrupted: false };
    spawns.push(rec);
    return {
      [Symbol.asyncIterator]: () => messages[Symbol.asyncIterator](),
      interrupt: async () => {
        rec.interrupted = true;
      },
    };
  }) as unknown as QueryFn;
  return { queryFn, spawns };
}

const opts = { name: "test", systemPrompt: "", allowedTools: [] };
const success = (result: string) => ({ type: "result", subtype: "success", result });
const textBlock = (text: string) => ({
  type: "assistant",
  message: { content: [{ type: "text", text }] },
});

// The wedge from issue #46: a turn that times out without a clean `result` (its
// interrupt best-effort) leaves its settled task at the queue head. The NEXT run
// must recycle the session rather than queue behind the wedged turn.
test("recycles a wedged session on the next run after a timeout (issue #46)", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);

  // Stream never emits a `result`; the short timeout resolves it as an error.
  const r1 = await session.run("task1", undefined, 20);
  assert.equal(r1.error, "timed out");
  assert.equal(spawns.length, 1);
  assert.equal(spawns[0].interrupted, true); // best-effort interrupt attempted

  // task1 is still the (settled) queue head, so run() must recycle: a new spawn.
  const r2p = session.run("task2", undefined, 100);
  assert.equal(spawns.length, 2);

  // task2's own stream resolves task2 — the stale head must not steal its result.
  spawns[1].messages.push(success("answer2"));
  const r2 = await r2p;
  assert.equal(r2.text, "answer2");
  assert.equal(r2.error, undefined);
});

// The desync half of #46: with a stale settled head, the loop's `!current.settled`
// guard would suppress the next task's streaming. After recycling, streaming and
// the final result must land on the new task.
test("streams text on the recycled session, stale head does not suppress it (issue #46)", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);

  const r1 = await session.run("task1", undefined, 20);
  assert.equal(r1.error, "timed out");

  const chunks: string[] = [];
  const r2p = session.run("task2", (acc) => chunks.push(acc), 100);
  assert.equal(spawns.length, 2);
  spawns[1].messages.push(textBlock("hello"));
  spawns[1].messages.push(success("hello world"));
  const r2 = await r2p;
  assert.deepEqual(chunks, ["hello"]);
  assert.equal(r2.text, "hello world");
});

// The warm-session optimisation must survive the normal (success) path: a run
// that resolves via `result` leaves the queue empty, so the next run reuses the
// same spawn rather than paying a cold start.
test("does not recycle on success, the warm session is reused (issue #46)", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);

  const r1p = session.run("task1", undefined, 100);
  assert.equal(spawns.length, 1);
  spawns[0].messages.push(success("a1"));
  assert.equal((await r1p).text, "a1");

  const r2p = session.run("task2", undefined, 100);
  assert.equal(spawns.length, 1); // reused — no new spawn
  spawns[0].messages.push(success("a2"));
  assert.equal((await r2p).text, "a2");
});

// reset() mid-flight (e.g. session_start rebuilding lanes, or the failure recycle)
// must settle an unresolved in-flight task so its caller's promise never hangs.
test("reset() settles an unresolved in-flight task (issue #46)", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);

  const r1p = session.run("task1", undefined, 100);
  assert.equal(spawns.length, 1);
  session.reset();
  const r1 = await r1p;
  assert.equal(r1.error, "agent session reset");

  // A run after the reset spawns fresh and resolves normally.
  const r2p = session.run("task2", undefined, 100);
  assert.equal(spawns.length, 2);
  spawns[1].messages.push(success("a2"));
  assert.equal((await r2p).text, "a2");
});
