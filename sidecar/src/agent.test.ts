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

/// Pushed into a fake stream to make it throw, as the SDK's does when the CLI
/// subprocess dies.
const streamFailure = (err: Error) => ({ type: "__fail__", err });

function makeFakeQuery(): { queryFn: QueryFn; spawns: FakeSpawn[] } {
  const spawns: FakeSpawn[] = [];
  const queryFn = ((args: unknown) => {
    const messages = new AsyncQueue<unknown>();
    const rec: FakeSpawn = { messages, interrupted: false, args };
    spawns.push(rec);
    return {
      [Symbol.asyncIterator]: () => {
        const it = messages[Symbol.asyncIterator]();
        return {
          next: async () => {
            const r = await it.next();
            const v = r.value as { type?: string; err?: Error } | undefined;
            if (!r.done && v?.type === "__fail__") throw v.err;
            return r;
          },
        };
      },
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
  const r2p = session.run("task2", { onText: (acc) => chunks.push(acc) }, 100);
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

test("logs each run's token usage", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const written: string[] = [];
  const orig = process.stderr.write;
  process.stderr.write = ((chunk: unknown) => {
    written.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    const r1p = session.run("task1", undefined, 1000);
    spawns[0].messages.push({
      ...success("{\"triggers\":[]}"),
      usage: { input_tokens: 129, output_tokens: 412, cache_read_input_tokens: 2048, cache_creation_input_tokens: 96 },
    });
    await r1p;
  } finally {
    process.stderr.write = orig;
  }
  const done = written.find((s) => s.includes("test: run done"));
  assert.ok(done?.includes("tokens in=129 out=412 cache_read=2048 cache_write=96"), written.join(""));
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

const streamEvent = (event: unknown, parent: string | null = null) =>
  ({ type: "stream_event", event, parent_tool_use_id: parent });
const assistant = (id: string, content: unknown[]) =>
  ({ type: "assistant", message: { id, content }, parent_tool_use_id: null });
/// A message with one text block streamed delta by delta: started, written,
/// and unless `finished` is false, completed as the CLI completes one — the
/// finished assistant message, then `message_stop`.
function streamText(spawn: FakeSpawn, id: string, deltas: string[], finished = true): void {
  spawn.messages.push(streamEvent({ type: "message_start", message: { id } }));
  spawn.messages.push(streamEvent({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }));
  for (const text of deltas) {
    spawn.messages.push(streamEvent({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }));
  }
  if (!finished) return;
  spawn.messages.push(assistant(id, [{ type: "text", text: deltas.join("") }]));
  spawn.messages.push(streamEvent({ type: "message_stop" }));
}

// Cards waited for each whole text block, which the model mostly writes in one
// go at the end of the turn (163 of 183 cards, 2026-10-09). Streaming the
// deltas puts text on the card while the model is still writing.
test("#card-token-stream text reaches the card as it is written, each block once", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const chunks: string[] = [];
  const rp = session.run("task", { onText: (acc) => chunks.push(acc) }, 1000);
  const { options } = spawns[0].args as { options: { includePartialMessages?: boolean } };
  assert.equal(options.includePartialMessages, true);

  streamText(spawns[0], "msg_1", ["Hello ", "world"]);
  streamText(spawns[0], "msg_2", ["Done."]);
  spawns[0].messages.push(success("Done."));
  await rp;
  assert.deepEqual(chunks, ["Hello ", "Hello world", "Hello world\n\nDone."]);
});

// Should the CLI ever deliver a message without its stream events (a
// non-streaming fallback), the finished block still reaches the card.
test("#card-token-stream a block that was not streamed is still added", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const chunks: string[] = [];
  const rp = session.run("task", { onText: (acc) => chunks.push(acc) }, 1000);
  streamText(spawns[0], "msg_1", ["From your notes: none."]);
  spawns[0].messages.push(assistant("msg_2", [{ type: "text", text: "Answer." }]));
  spawns[0].messages.push(success("Answer."));
  await rp;
  assert.deepEqual(chunks, ["From your notes: none.", "From your notes: none.\n\nAnswer."]);
});

// Only calls the sandbox lets run are shown: a denied read of a credential
// file must not appear on the card as if it happened.
test("#card-activity thinking and the tool calls the sandbox allows are reported as activity", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const activity: string[] = [];
  const rp = session.run("task", { onActivity: (a) => activity.push(a) }, 1000);
  const { options } = spawns[0].args as {
    options: { hooks: { PreToolUse: { hooks: ((...a: unknown[]) => Promise<unknown>)[] }[] } };
  };
  const gate = options.hooks.PreToolUse[0].hooks[0];
  const settle = () => new Promise((r) => setTimeout(r, 0));
  spawns[0].messages.push(streamEvent({ type: "message_start", message: { id: "msg_1" } }));
  spawns[0].messages.push(streamEvent({ type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } }));
  // As the CLI does it: the model's tool call, then the gate's decision on it.
  for (const [name, input] of [
    ["ToolSearch", { query: "slack" }],
    ["WebSearch", { query: "Cedar migration" }],
    ["Read", { file_path: "~/.ssh/id_rsa" }],
  ] as const) {
    spawns[0].messages.push(assistant("msg_1", [{ type: "tool_use", id: `t_${name}`, name, input }]));
    await settle();
    await gate(
      { hook_event_name: "PreToolUse", tool_name: name, tool_input: input },
      `t_${name}`,
      { signal: new AbortController().signal },
    );
  }
  spawns[0].messages.push(success("ok"));
  await rp;
  assert.deepEqual(activity, ["Thinking…", "Searching the web for “Cedar migration”"]);
});

// The CLI replaces a message whose stream broke off — retrying it, or falling
// back to a non-streaming request — under a new id. The broken message's text
// must leave the card, or it shows twice.
test("#card-token-stream a retried message replaces the one that broke off", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const chunks: string[] = [];
  const rp = session.run("task", { onText: (acc) => chunks.push(acc) }, 1000);
  streamText(spawns[0], "msg_1", ["From your notes: none."]);
  streamText(spawns[0], "msg_2", ["Cedar is ", "the"], false);
  streamText(spawns[0], "msg_3", ["Cedar is ", "the migration."]);
  spawns[0].messages.push(success("Cedar is the migration."));
  await rp;
  assert.equal(chunks.at(-1), "From your notes: none.\n\nCedar is the migration.");
  assert.ok(!chunks.some((c) => c.includes("the\n\nCedar")), JSON.stringify(chunks));
});

test("#card-token-stream a non-streaming fallback replaces the message that broke off", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const chunks: string[] = [];
  const rp = session.run("task", { onText: (acc) => chunks.push(acc) }, 1000);
  streamText(spawns[0], "msg_1", ["Cedar is ", "the"], false);
  spawns[0].messages.push(assistant("msg_2", [{ type: "text", text: "Cedar is the migration." }]));
  spawns[0].messages.push(success("Cedar is the migration."));
  await rp;
  assert.equal(chunks.at(-1), "Cedar is the migration.");
});

// The SDK reports some failures — a logged-out CLI's "Not logged in · Please
// run /login" among them (auth.sdk.test.ts has the real shape) — as a `success`
// result with `is_error` set and the message in `result`. Taking that at face
// value put the error on the card as a finished answer (code review 2026-10-17).
test("#result-error a success result flagged is_error is a failure, not an answer", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const rp = session.run("task", undefined, 1000);
  spawns[0].messages.push({
    type: "result", subtype: "success", is_error: true, result: "Not logged in · Please run /login",
  });
  const r = await rp;
  assert.equal(r.text, "");
  assert.equal(r.error, "Not logged in · Please run /login");
});

// The CLI echoes the failure as an assistant block flagged with it (`error:
// "authentication_failed"`), after any text the model did stream. Neither the
// echo-only nor the echo-after-text shape may put the CLI's words in the answer.
test("#result-error the CLI's flagged echo of the error is not answer text", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const rp = session.run("task", undefined, 1000);
  spawns[0].messages.push(textBlock("Cedar is the"));
  spawns[0].messages.push({
    type: "assistant", error: "server_error", message: { content: [{ type: "text", text: "Request failed" }] },
  });
  spawns[0].messages.push({ type: "result", subtype: "success", is_error: true, result: "Request failed" });
  const r = await rp;
  assert.equal(r.text, "Cedar is the");
  assert.equal(r.error, "Request failed");
});

// A message cut off by the output cap is flagged too, but its text is the
// model's answer so far and stays.
test("#result-error a max_output_tokens message keeps its text", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const chunks: string[] = [];
  const rp = session.run("task", { onText: (acc) => chunks.push(acc) }, 1000);
  spawns[0].messages.push({
    type: "assistant", error: "max_output_tokens", message: { content: [{ type: "text", text: "Cedar is the" }] },
  });
  // A flagged result, so the answer is the buffer: the cut-off text must be in it.
  spawns[0].messages.push({ type: "result", subtype: "success", is_error: true, result: "Output limit reached" });
  const r = await rp;
  assert.deepEqual(chunks, ["Cedar is the"]); // and it streamed to the card
  assert.equal(r.text, "Cedar is the");
  assert.equal(r.error, "Output limit reached");
});

// The CLI survives some flagged results (an API 400 such as "prompt is too
// long" — probed against the real CLI) and answers the next prompt, so the
// session is kept warm rather than cold-spawned on every recoverable error.
test("#result-error a flagged result does not throw away a live session", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const r1p = session.run("task1", undefined, 1000);
  spawns[0].messages.push({ type: "result", subtype: "success", is_error: true, result: "Prompt is too long" });
  assert.equal((await r1p).error, "Prompt is too long");
  const r2p = session.run("task2", undefined, 1000);
  assert.equal(spawns.length, 1); // reused
  spawns[0].messages.push(success("a2"));
  assert.equal((await r2p).text, "a2");
});

// The error goes onto the card as one italic line; the CLI's can be a JSON body
// or a stack trace.
test("#result-error a multi-line error is cut to its first line, bounded", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const rp = session.run("task", undefined, 1000);
  spawns[0].messages.push({
    type: "result", subtype: "error_during_execution", is_error: true,
    errors: [`{"type":"error","message":"${"x".repeat(300)}"}\n    at stack line`],
  });
  const r = await rp;
  assert.ok(!r.error?.includes("\n"), r.error ?? "");
  assert.ok((r.error?.length ?? 0) <= "error_during_execution: ".length + 200, `${r.error?.length}`);
  assert.ok(r.error?.startsWith('error_during_execution: {"type":"error"'), r.error ?? "");
});

test("#result-error a success result with no result string is an empty answer, not a dead session", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const rp = session.run("task", undefined, 1000);
  spawns[0].messages.push({ type: "result", subtype: "success", is_error: false });
  assert.deepEqual(await rp, { text: "" });
  const r2p = session.run("task2", undefined, 1000);
  assert.equal(spawns.length, 1); // the session survived
  spawns[0].messages.push(success("a2"));
  assert.equal((await r2p).text, "a2");
});

test("#result-error text streamed before a flagged failure is kept as a partial answer", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const rp = session.run("task", undefined, 1000);
  spawns[0].messages.push(textBlock("Cedar is the"));
  spawns[0].messages.push({ type: "result", subtype: "success", is_error: true, result: "Request failed" });
  const r = await rp;
  assert.equal(r.text, "Cedar is the");
  assert.equal(r.error, "Request failed");
});

test("#result-error an error result carries the CLI's own message, not just its subtype", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const rp = session.run("task", undefined, 1000);
  spawns[0].messages.push({
    type: "result", subtype: "error_during_execution", is_error: true, errors: ["rate limited"],
  });
  const r = await rp;
  assert.equal(r.error, "error_during_execution: rate limited");
});

// A CLI that is missing or crashes at spawn ends the stream with a throw. The
// card used to say only "agent session ended", with the cause in stderr alone.
test("#result-error a session that dies names its cause", async () => {
  const { queryFn, spawns } = makeFakeQuery();
  const session = new AgentSession(opts, queryFn);
  const rp = session.run("task", undefined, 1000);
  spawns[0].messages.push(streamFailure(new Error("Claude Code process exited with code 1")));
  const r = await rp;
  assert.equal(r.error, "agent session ended: Claude Code process exited with code 1");
});
