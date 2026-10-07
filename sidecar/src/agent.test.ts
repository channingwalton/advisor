import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { AgentSession, AsyncQueue, agentCwd, type QueryFn } from "./agent.js";

// A controllable fake of the SDK's `query()` stream: an async-iterable of
// messages the test pushes into `messages`, plus an `interrupt()` spy. Each call
// to the returned queryFn records a fresh spawn, so a test can assert whether the
// session recycled (a new spawn) or reused a warm one, and drive each generation
// independently. Injecting this exercises the full run/timeout/reset lifecycle
// without spawning a real SDK subprocess (see issue #46).
interface FakeSpawn {
  messages: AsyncQueue<unknown>;
  interrupted: boolean;
  args: unknown;
}

function makeFakeQuery(): { queryFn: QueryFn; spawns: FakeSpawn[] } {
  const spawns: FakeSpawn[] = [];
  const queryFn = ((args: unknown) => {
    const messages = new AsyncQueue<unknown>();
    const rec: FakeSpawn = { messages, interrupted: false, args };
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

// A synthetic home, so sessions create their default working folder there
// rather than in the real ~/Library.
const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-agent-home-")));
process.on("exit", () => fs.rmSync(home, { recursive: true, force: true }));
const opts = { name: "test", systemPrompt: "", allowedTools: [], home };
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

// reset() + immediate run() on the SAME instance: the old stream's async
// teardown must splice only its own captured pending array, never the new
// task's. Were `pending` shared across spawns, the old finally would resolve
// task2 with "agent session ended" and the next result would desync the FIFO
// (issue #57). Guards the per-spawn capture from issue #46.
test("reset() then immediate run() keeps the new task off the old teardown (issue #57)", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);

  const r1p = session.run("task1", undefined, 1000);
  assert.equal(spawns.length, 1);
  session.reset();
  assert.equal((await r1p).error, "agent session reset");

  // task2 spawns fresh (spawn 2) with its own pending array.
  const r2p = session.run("task2", undefined, 1000);
  assert.equal(spawns.length, 2);

  // Now let spawn 1's stream end so its finally runs *after* task2 is enqueued.
  spawns[0].messages.end();
  await new Promise((r) => setTimeout(r, 0));

  spawns[1].messages.push(success("answer2"));
  const r2 = await r2p;
  assert.equal(r2.text, "answer2"); // not "" with error "agent session ended"
  assert.equal(r2.error, undefined);
});

// The CLI subprocess's stderr was dropped, so a spawn-time crash surfaced only
// as "exited with code 1" (the v0.2.0 DMG's entitlement break). The session
// must hand the SDK a stderr callback that logs lines under the session name.
test("passes the SDK a stderr callback that logs CLI stderr", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);

  const r1p = session.run("task1", undefined, 100);
  const { options } = spawns[0].args as { options: { stderr?: (data: string) => void } };
  assert.equal(typeof options.stderr, "function");

  const written: string[] = [];
  const orig = process.stderr.write;
  process.stderr.write = ((chunk: unknown) => {
    written.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    // A real crash dump is one multi-KB chunk with the error at the END (the
    // v0.2.0 break: ~2.5KB of minified source context first). The error line
    // must survive logging, so the callback must split lines, not cap the chunk.
    options.stderr!(`${"x".repeat(3000)}\n\nReferenceError: SharedArrayBuffer is not defined\n`);
  } finally {
    process.stderr.write = orig;
  }
  assert.ok(
    written.some((s) => s.includes("test: cli stderr: ReferenceError: SharedArrayBuffer is not defined")),
    `buried stderr line not logged: ${JSON.stringify(written.map((s) => s.slice(0, 80)))}`,
  );

  spawns[0].messages.push(success("done"));
  await r1p;
});

// The SDK approves reads inside its cwd before canUseTool is asked, so the
// session must register the PreToolUse gate and run from Advisor's own empty
// folder rather than $HOME (code review 2026-10-06).
test("#sandbox-sdk-gate registers the PreToolUse gate and runs in Advisor's own folder", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const r1p = session.run("task1", undefined, 100);
  const { options } = spawns[0].args as {
    options: { cwd?: string; hooks?: { PreToolUse?: { hooks: ((...a: unknown[]) => Promise<unknown>)[] }[] } };
  };
  assert.equal(options.cwd, agentCwd(home));
  assert.ok(options.cwd!.startsWith(home + path.sep));
  const gate = options.hooks?.PreToolUse?.[0]?.hooks[0];
  assert.equal(typeof gate, "function");
  const out = (await gate!(
    { hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "cat ~/.ssh/id_rsa" } },
    "toolu_1",
    { signal: new AbortController().signal },
  )) as { hookSpecificOutput?: { permissionDecision?: string } };
  assert.equal(out.hookSpecificOutput?.permissionDecision, "deny");
  spawns[0].messages.push(success("done"));
  await r1p;
});

// The working directory is created by the session that needs it, not as a
// startup side effect of main.ts — a missing folder would make every spawn fail,
// and an unwritable one crashed the sidecar before its error handlers existed.
test("creates its working directory before spawning, and reports a failure as a failed run", {
  skip: process.getuid?.() === 0 ? "root ignores the read-only folder" : false,
}, async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "advisor-cwd-"));
  t.after(() => { fs.chmodSync(root, 0o755); fs.rmSync(root, { recursive: true, force: true }); });
  const cwd = path.join(root, "a", "agent-cwd");
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession({ ...opts, cwd }, queryFn);
  const r1p = session.run("task1", undefined, 100);
  assert.ok(fs.statSync(cwd).isDirectory());
  spawns[0].messages.push(success("done"));
  await r1p;

  fs.chmodSync(root, 0o555);
  const blocked = new AgentSession({ ...opts, cwd: path.join(root, "b", "agent-cwd") }, queryFn);
  // A result, not a rejection: callers such as classify() count it as a failed
  // turn (and bound retries) instead of bypassing their failure handling.
  const r2 = await blocked.run("task2", undefined, 100);
  assert.match(r2.error ?? "", /EACCES/);
});

// The effort preference must reach the SDK, and be visible in the log so card
// latency can be compared by level. Unset, the option is omitted so the CLI
// keeps the user's own Claude setting.
test("passes the effort level to the SDK and logs it on each run", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession({ ...opts, effort: "low" }, queryFn);
  const written: string[] = [];
  const orig = process.stderr.write;
  process.stderr.write = ((chunk: unknown) => {
    written.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  let r1p;
  try {
    r1p = session.run("task1", undefined, 1000);
  } finally {
    process.stderr.write = orig;
  }
  const { options } = spawns[0].args as { options: { effort?: string } };
  assert.equal(options.effort, "low");
  assert.ok(written.some((s) => s.includes("test: run start") && s.includes("effort=low")), written.join(""));
  spawns[0].messages.push(success("done"));
  await r1p;
});

test("omits the effort option when none is set", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const r1p = session.run("task1", undefined, 1000);
  const { options } = spawns[0].args as { options: Record<string, unknown> };
  assert.equal(options.effort, undefined);
  spawns[0].messages.push(success("done"));
  await r1p;
});
