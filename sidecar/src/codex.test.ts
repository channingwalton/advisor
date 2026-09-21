import { test } from "node:test";
import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import { Thread, type ThreadEvent, type ThreadOptions } from "@openai/codex-sdk";
import { CodexAgentSession, codexConstructorOptions, codexThreadOptions } from "./codex.js";
import { AsyncQueue } from "./agent.js";
import { handleCancel } from "./cancel.js";
import { guardedRun } from "./guardedRun.js";
import type { Outbound } from "./protocol.js";

const base = { name: "x", systemPrompt: "sp", allowedTools: [] as string[] };

interface Invocation {
  input: string;
  threadId: string | null;
  signal: AbortSignal;
  events: AsyncQueue<string>;
}

// Exercise the installed SDK's real thread-ID handling while controlling when
// the CLI would emit each event. Deliberately permit late events after abort.
function controlledThreads() {
  const calls: Invocation[] = [];
  const factory = (options: ThreadOptions): Thread => Reflect.construct(Thread, [{
    run(args: Omit<Invocation, "events">) {
      const events = new AsyncQueue<string>();
      calls.push({ ...args, events });
      return events;
    },
  }, {}, options]);
  return { calls, factory };
}

function emit(call: Invocation, event: ThreadEvent): void {
  call.events.push(JSON.stringify(event));
}

function complete(call: Invocation, text: string, threadId = "conversation"): void {
  emit(call, { type: "thread.started", thread_id: threadId });
  emit(call, {
    type: "item.completed",
    item: { id: "answer", type: "agent_message", text },
  });
  emit(call, {
    type: "turn.completed",
    usage: { input_tokens: 1, cached_input_tokens: 0, output_tokens: 1, reasoning_output_tokens: 0 },
  });
  call.events.end();
}

test("#codex-session-fifo delayed warm-up retains instructions and real conversation context", async () => {
  const { calls, factory } = controlledThreads();
  const session = new CodexAgentSession(base, factory);
  const warm = session.run("warm-up; reply READY");
  const first = session.run("first real request");
  const later = session.run("later real request");
  await setImmediate();

  assert.equal(calls.length, 1, "real requests must wait for warm-up startup and completion");
  assert.equal(calls[0].threadId, null);
  assert.equal(calls[0].input, "sp\n\nwarm-up; reply READY");
  emit(calls[0], { type: "thread.started", thread_id: "conversation" });
  await setImmediate();
  assert.equal(calls.length, 1, "receiving the thread ID must not release an unfinished turn");
  complete(calls[0], "READY");
  assert.equal((await warm).text, "READY");
  await setImmediate();

  assert.equal(calls.length, 2);
  assert.equal(calls[1].threadId, "conversation", "first request inherits warm-up instructions");
  assert.equal(calls[1].input, "first real request");
  complete(calls[1], "first answer");
  assert.equal((await first).text, "first answer");
  await setImmediate();

  assert.equal(calls.length, 3);
  assert.equal(calls[2].threadId, "conversation", "later request resumes the real conversation");
  assert.equal(calls[2].input, "later real request");
  complete(calls[2], "later answer");
  assert.equal((await later).text, "later answer");
});

test("#codex-session-reset abandons active and queued work before accepting a fresh conversation", async () => {
  const { calls, factory } = controlledThreads();
  const session = new CodexAgentSession(base, factory);
  const oldText: string[] = [];
  const active = session.run("old warm-up", (text) => oldText.push(text));
  const queued = session.run("old real request");
  await setImmediate();
  session.reset();
  assert.deepEqual(await active, { text: "", error: "agent session reset" });
  assert.deepEqual(await queued, { text: "", error: "agent session reset" });
  assert.equal(calls[0].signal.aborted, true);

  const fresh = session.run("fresh request");
  await setImmediate();
  assert.equal(calls.length, 2, "queued work from the old session must never start");
  assert.equal(calls[1].threadId, null);
  assert.equal(calls[1].input, "sp\n\nfresh request");
  emit(calls[1], { type: "thread.started", thread_id: "fresh" });
  await setImmediate();
  complete(calls[0], "stale answer", "old");
  await setImmediate();
  assert.deepEqual(oldText, [], "late events must not update an abandoned card");
  complete(calls[1], "fresh answer", "fresh");
  assert.equal((await fresh).text, "fresh answer");

  const later = session.run("follow-up");
  await setImmediate();
  assert.equal(calls[2].threadId, "fresh", "late old startup must not replace fresh context");
  assert.equal(calls[2].input, "follow-up");
  complete(calls[2], "follow-up answer", "fresh");
  await later;
});

test("#codex-session-cancel cancelling a card queued behind warm-up prevents its dispatch and releases its lane", async () => {
  const { calls, factory } = controlledThreads();
  const session = new CodexAgentSession(base, factory);
  const warm = session.run("warm-up");
  const lane = { name: "research0", currentCardId: "c1", session, busy: true };
  const sent: Outbound[] = [];
  const deps = { cancelledCards: new Set<string>(), send: (message: Outbound) => sent.push(message) };
  const card = guardedRun(
    session, "c1", "cancelled real request",
    (body, state) => ({ type: "card_update", id: "c1", body, state }), "research", deps,
  ).finally(() => { lane.busy = false; });
  await setImmediate();
  handleCancel("c1", { ...deps, cardLanes: [lane], documentLanes: [] });
  await setImmediate();
  assert.equal(calls.length, 1, "a cancelled queued card must never reach the provider");
  assert.equal(lane.busy, false, "cancellation must settle the queued request immediately");
  await Promise.all([warm, card]);
  assert.equal(calls[0].signal.aborted, true);
  assert.deepEqual(sent, [{ type: "card_update", id: "c1", body: "cancelled", state: "cancelled" }]);

  const fresh = session.run("next card");
  await setImmediate();
  assert.equal(calls[1].input, "sp\n\nnext card");
  assert.equal(calls[1].threadId, null);
  complete(calls[0], "stale warm-up");
  complete(calls[1], "next answer", "next");
  assert.equal((await fresh).text, "next answer");
});

test("timed-out warm-up retires its thread and releases queued requests", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  {
    const { calls, factory } = controlledThreads();
    const session = new CodexAgentSession(base, factory);
    const updates: string[] = [];
    const active = session.run("warm-up", (text) => updates.push(text), 25);
    const queued = session.run("real request", undefined, 100);
    await setImmediate();
    emit(calls[0], {
      type: "item.updated",
      item: { type: "agent_message", id: "partial", text: "partial" },
    });
    await setImmediate();

    t.mock.timers.tick(25);
    assert.deepEqual(await active, {
      text: "partial", error: "timed out",
    });
    await setImmediate();
    assert.equal(calls[0].signal.aborted, true);
    assert.equal(calls.length, 2, "the queue must progress even if abort produces no event");
    assert.equal(calls[1].signal.aborted, false);
    assert.equal(calls[1].threadId, null);
    assert.equal(calls[1].input, "sp\n\nreal request");
    emit(calls[0], { type: "error", message: "late abandoned error" });
    calls[0].events.end();
    await setImmediate();
    assert.deepEqual(updates, ["partial"]);

    complete(calls[1], "real answer", "real");
    assert.equal((await queued).text, "real answer");
    const later = session.run("follow-up");
    await setImmediate();
    assert.equal(calls[2].threadId, "real", "late abandoned failure must not drop the new thread");
    complete(calls[2], "follow-up answer", "real");
    await later;
  }
});

test("#codex-session-recovery failed startup or warm-up restores instructions for queued requests", async () => {
  for (const failure of ["startup", "turn"] as const) {
    const { calls, factory } = controlledThreads();
    let attempts = 0;
    const session = new CodexAgentSession(base, (options) => {
      if (++attempts === 1 && failure === "startup") throw new Error("startup failed");
      return factory(options);
    });
    const warm = session.run("warm-up");
    const real = session.run("real request");
    await setImmediate();
    if (failure === "turn") {
      emit(calls[0], { type: "thread.started", thread_id: "failed" });
      emit(calls[0], { type: "turn.failed", error: { message: "turn failed" } });
      calls[0].events.end();
    }
    assert.equal((await warm).error, `${failure} failed`);
    await setImmediate();
    const request = calls.at(-1)!;
    assert.equal(attempts, 2);
    assert.equal(request.threadId, null);
    assert.equal(request.input, "sp\n\nreal request");
    complete(request, "real answer");
    assert.equal((await real).text, "real answer");
  }
});

test("independent Codex sessions can run concurrently", async () => {
  const { calls, factory } = controlledThreads();
  const first = new CodexAgentSession(base, factory).run("first session");
  const second = new CodexAgentSession(base, factory).run("second session");
  await setImmediate();
  assert.equal(calls.length, 2);
  complete(calls[1], "second answer", "second");
  assert.equal((await second).text, "second answer");
  complete(calls[0], "first answer", "first");
  assert.equal((await first).text, "first answer");
});

test("codexThreadOptions sandboxes read-only with no approval", () => {
  const o = codexThreadOptions(base);
  assert.equal(o.sandboxMode, "read-only");
  assert.equal(o.approvalPolicy, "never");
  assert.equal(o.skipGitRepoCheck, true);
});

test("codexThreadOptions enables web only when a Web tool is allowed", () => {
  assert.equal(codexThreadOptions(base).webSearchEnabled, false);
  assert.equal(codexThreadOptions(base).networkAccessEnabled, false);
  const web = codexThreadOptions({ ...base, allowedTools: ["WebSearch", "Read"] });
  assert.equal(web.webSearchEnabled, true);
  assert.equal(web.networkAccessEnabled, true);
});

test("codexConstructorOptions passes apiKey only when OPENAI_API_KEY is set", () => {
  assert.deepEqual(codexConstructorOptions({ OPENAI_API_KEY: "sk-x" }), { apiKey: "sk-x" });
  // Absent or empty → no apiKey, so the SDK falls back to the Codex CLI login.
  assert.deepEqual(codexConstructorOptions({}), {});
  assert.deepEqual(codexConstructorOptions({ OPENAI_API_KEY: "" }), {});
});

test("codexThreadOptions passes the model through and defaults cwd to home", () => {
  const o = codexThreadOptions({ ...base, model: "gpt-5-codex", cwd: "/tmp/work" });
  assert.equal(o.model, "gpt-5-codex");
  assert.equal(o.workingDirectory, "/tmp/work");
  assert.equal(codexThreadOptions(base).model, undefined);
  assert.notEqual(codexThreadOptions(base).workingDirectory, undefined);
});

test("successful run releases its timeout and controller state", async () => {
  let signal: AbortSignal | undefined;
  const thread = {
    runStreamed: async (_input: string, options: { signal?: AbortSignal }) => {
      signal = options.signal;
      return {
        events: (async function* () {
          yield {
            type: "item.completed",
            item: { id: "answer", type: "agent_message", text: "done" },
          };
        })(),
      };
    },
  } as unknown as Thread;

  let unrefed = false;
  let cleared = false;
  const timer = {
    unref: () => {
      unrefed = true;
      return timer;
    },
  } as unknown as NodeJS.Timeout;
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  globalThis.setTimeout = (() => timer) as unknown as typeof setTimeout;
  globalThis.clearTimeout = ((handle: NodeJS.Timeout) => {
    assert.equal(handle, timer);
    cleared = true;
  }) as typeof clearTimeout;

  try {
    const session = new CodexAgentSession(base, () => thread);
    assert.deepEqual(await session.run("task"), { text: "done", error: undefined });
    assert.equal(unrefed, true);
    assert.equal(cleared, true);

    await session.interrupt();
    assert.equal(signal?.aborted, false);
  } finally {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  }
});

test("failed run releases its controller before reset (issue #72)", async () => {
  let signal: AbortSignal | undefined;
  const thread = {
    runStreamed: async (_input: string, options: { signal: AbortSignal }) => {
      signal = options.signal;
      return {
        events: (async function* () {
          throw new Error("invalid API key");
        })(),
      };
    },
  } as unknown as Thread;
  const session = new CodexAgentSession(base, () => thread);

  const result = await session.run("task", undefined, 60_000);
  assert.equal(result.error, "invalid API key");
  session.reset();
  assert.equal(signal?.aborted, false);
});

test("completed run does not release a newer run's controller", async () => {
  let releaseFirst!: () => void;
  let releaseSecond!: () => void;
  const gates = [
    new Promise<void>((resolve) => (releaseFirst = resolve)),
    new Promise<void>((resolve) => (releaseSecond = resolve)),
  ];
  const signals: AbortSignal[] = [];
  let run = 0;
  const thread = {
    runStreamed: async (_input: string, options: { signal: AbortSignal }) => {
      const index = run++;
      signals.push(options.signal);
      return {
        events: (async function* () {
          await gates[index];
          yield {
            type: "item.completed",
            item: { id: `answer-${index}`, type: "agent_message", text: `done-${index}` },
          };
        })(),
      };
    },
  } as unknown as Thread;
  const session = new CodexAgentSession(base, () => thread);

  const first = session.run("first", undefined, 60_000);
  const second = session.run("second", undefined, 60_000);
  releaseFirst();
  assert.equal((await first).text, "done-0");

  await session.interrupt();
  assert.equal(signals[0].aborted, false);
  assert.equal(signals[1].aborted, true);

  releaseSecond();
  await second;
});
