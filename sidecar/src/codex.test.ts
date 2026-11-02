import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { setImmediate } from "node:timers/promises";
import { type Codex, Thread, type ThreadEvent, type ThreadOptions } from "@openai/codex-sdk";
import {
  CodexAgentSession,
  codexClientOptions,
  codexConfigServers,
  codexConstructorOptions,
  codexThreadOptions,
} from "./codex.js";
import { AsyncQueue } from "./agent.js";
import { handleCancel } from "./cancel.js";
import { guardedRun } from "./guardedRun.js";
import { runCard, Transcript, type Lane } from "./lanes.js";
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
    usage: {
      input_tokens: 1,
      cached_input_tokens: 0,
      cache_write_input_tokens: 0,
      output_tokens: 1,
      reasoning_output_tokens: 0,
    },
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
  const active = session.run("old warm-up", { onText: (text) => oldText.push(text) });
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
  const [, queued] = await Promise.all([warm, card]);
  assert.equal(queued.contextLost, true, "the queued card's prompt never reached a thread");
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

test("#context-lane-recycle the card after a cancelled Codex card is sent the whole conversation again", async () => {
  const { calls, factory } = controlledThreads();
  const session = new CodexAgentSession(base, factory);
  const transcript = new Transcript();
  const lane: Lane = { name: "query0", session, busy: true };
  let n = 0;
  const cancelledCards = new Set<string>();
  const send = (_message: Outbound) => {};
  const deps = { transcript, nextCardId: () => `c${++n}`, sessionContext: () => "", cancelledCards, send };
  const say = (id: string, text: string) => transcript.push({ id, source: "them", text, ts: 0 });

  say("u1", "Our migration is named Cedar");
  const cancelled = runCard(lane, "query", "Cedar", "Question: what is Cedar?", undefined, deps);
  await setImmediate();
  assert.match(calls[0].input, /Cedar/);
  handleCancel("c1", { cancelledCards, cardLanes: [lane], documentLanes: [], send });
  await cancelled;
  calls[0].events.end(); // the aborted CLI's stream closes

  say("u2", "Who owns it?");
  const next = runCard(lane, "query", "owner", "Question: who owns it?", undefined, deps);
  await setImmediate();
  assert.equal(calls[1].threadId, null, "the cancel discarded the thread");
  // The new thread never saw u1, so the prompt must carry it again.
  assert.match(calls[1].input, /Cedar/);
  assert.match(calls[1].input, /Who owns it\?/);
  complete(calls[1], "Priya", "next");
  await next;
});

test("timed-out warm-up retires its thread and releases queued requests", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  {
    const { calls, factory } = controlledThreads();
    const session = new CodexAgentSession(base, factory);
    const updates: string[] = [];
    const active = session.run("warm-up", { onText: (text) => updates.push(text) }, 25);
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

/// A Codex client whose setup (listing the user's servers, in the app) the
/// test resolves or rejects, starting controlled threads.
function controlledClient() {
  const { calls, factory } = controlledThreads();
  const setups: { resolve: (codex: Codex) => void; reject: (err: Error) => void }[] = [];
  const create = (): Promise<Codex> => new Promise((resolve, reject) => setups.push({ resolve, reject }));
  const client = { startThread: factory } as unknown as Codex;
  return { calls, create, client, setups };
}

async function until(condition: () => boolean): Promise<void> {
  for (let i = 0; i < 50 && !condition(); i++) await setImmediate();
  assert.ok(condition(), "condition never held");
}

test("#codex-connectors a task stopped during client setup leaves the next task a thread with instructions", async (t) => {
  // The session's timeout timer is unref'd, so it doesn't keep the event loop
  // alive, and a pending setup holds nothing open: with a real timer the test
  // runner can end the test before the timer fires (Node 22's did).
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const { calls, create, client, setups } = controlledClient();
  const session = new CodexAgentSession(base, undefined, create);
  const warm = session.run("warm-up", undefined, 10);
  const first = session.run("first", undefined, 60_000);
  await until(() => setups.length === 1);
  t.mock.timers.tick(10);
  assert.equal((await warm).error, "timed out");

  // One setup serves both: the stopped task's must not start a second thread
  // that later replaces the one the next task is on.
  setups[0].resolve(client);
  await until(() => calls.length === 1);
  assert.equal(calls[0].input, "sp\n\nfirst");
  complete(calls[0], "one");
  assert.equal((await first).text, "one");

  const second = session.run("second", undefined, 60_000);
  await until(() => calls.length === 2);
  assert.equal(calls[1].threadId, "conversation");
  assert.equal(calls[1].input, "second");
  complete(calls[1], "two");
  assert.equal((await second).text, "two");
  assert.equal(setups.length, 1);
});

test("#codex-connectors reset sets the client up again, so a recycled lane lists the servers again", async () => {
  const { calls, create, client, setups } = controlledClient();
  const session = new CodexAgentSession(base, undefined, create);
  const first = session.run("first", undefined, 60_000);
  setups[0].resolve(client);
  await until(() => calls.length === 1);
  complete(calls[0], "one");
  await first;

  session.reset();
  const after = session.run("after", undefined, 60_000);
  await until(() => setups.length === 2);
  setups[1].resolve(client);
  await until(() => calls.length === 2);
  assert.equal(calls[1].input, "sp\n\nafter");
  complete(calls[1], "two");
  assert.equal((await after).text, "two");
});

test("#codex-connectors a failed client setup fails its task, and the next task sets up again", async () => {
  const { calls, create, client, setups } = controlledClient();
  const session = new CodexAgentSession(base, undefined, create);
  const first = session.run("first", undefined, 60_000);
  await until(() => setups.length === 1);
  setups[0].reject(new Error("listing Codex MCP servers failed: broken"));
  assert.match((await first).error ?? "", /broken/);
  assert.equal(calls.length, 0, "no turn runs without the servers disabled");

  const second = session.run("second", undefined, 60_000);
  await until(() => setups.length === 2);
  setups[1].resolve(client);
  await until(() => calls.length === 1);
  assert.equal(calls[0].input, "sp\n\nsecond");
  complete(calls[0], "two");
  assert.equal((await second).text, "two");
});

test("#codex-connectors a failed turn sets the client up again, so a removed server stops failing turns", async () => {
  // A server removed from config.toml mid-recording leaves its override naming
  // a server with no command, which the CLI rejects on every turn. The
  // classifier is never reset, so the session must list again by itself.
  const { calls, create, client, setups } = controlledClient();
  const session = new CodexAgentSession(base, undefined, create);
  const first = session.run("first", undefined, 60_000);
  setups[0].resolve(client);
  await until(() => calls.length === 1);
  emit(calls[0], { type: "turn.failed", error: { message: "failed to load configuration: invalid transport" } });
  calls[0].events.end();
  assert.match((await first).error ?? "", /invalid transport/);

  const second = session.run("second", undefined, 60_000);
  await until(() => setups.length === 2);
  setups[1].resolve(client);
  await until(() => calls.length === 2);
  assert.equal(calls[1].input, "sp\n\nsecond");
  complete(calls[1], "two");
  assert.equal((await second).text, "two");
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

/// Stands in for `codexConfigServers`: the servers the user's config defines.
function servers(names: string[]) {
  const calls: { codexPath: string; cwd: string }[] = [];
  const list = async (codexPath: string, cwd: string): Promise<string[]> => {
    calls.push({ codexPath, cwd });
    return names;
  };
  return { calls, list };
}
const NO_CONNECTORS = { apps: false, plugins: false };

test("#codex-connectors a card lane allowed connector actions keeps the user's connectors", async () => {
  const { calls, list } = servers(["fff"]);
  assert.deepEqual(await codexClientOptions({ ...base, allowMcpActions: true }, {}, "/w/codex", list), {
    codexPathOverride: "/w/codex",
  });
  assert.deepEqual(calls, []);
});

test("#codex-connectors a card lane without connector actions disables each server and drops apps and plugins", async () => {
  for (const allowMcpActions of [false, undefined]) {
    const { calls, list } = servers(["fff", "openai-docs"]);
    const o = await codexClientOptions({ ...base, allowMcpActions, cwd: "/work" }, {}, "/w/codex", list);
    assert.deepEqual(o, {
      codexPathOverride: "/w/codex",
      config: {
        features: NO_CONNECTORS,
        mcp_servers: { fff: { enabled: false }, "openai-docs": { enabled: false } },
      },
    });
    // Listed by the CLI the session runs, from the directory it runs in.
    assert.deepEqual(calls, [{ codexPath: "/w/codex", cwd: "/work" }]);
  }
});

test("#codex-connectors with no servers configured only apps and plugins are switched off", async () => {
  assert.deepEqual(await codexClientOptions(base, {}, "/w/codex", servers([]).list), {
    codexPathOverride: "/w/codex",
    config: { features: NO_CONNECTORS },
  });
});

test("#codex-connectors a server name that can't be a config key fails the session", async () => {
  // `codex mcp add` refuses such names, but config.toml can quote one. Its
  // override path would name a different key, leaving the server running.
  await assert.rejects(codexClientOptions(base, {}, "/w/codex", servers(["a.b"]).list), /a\.b/);
});

test("#classifier-no-tools a Codex session with no tools also drops the shell, goals, image generation, sleep and sub-agents", async () => {
  const features = {
    ...NO_CONNECTORS, shell_tool: false, unified_exec: false, goals: false, image_generation: false, sleep_tool: false,
    multi_agent: false, multi_agent_v2: false,
  };
  // A model can turn sub-agents on by itself; only `[agents] enabled` turns them off.
  const agents = { enabled: false };
  // noTools wins over allowMcpActions: the classifier needs no connectors at all.
  const o = await codexClientOptions({ ...base, noTools: true, allowMcpActions: true }, {}, "/w/codex", servers(["fff"]).list);
  assert.deepEqual(o.config, { features, agents, mcp_servers: { fff: { enabled: false } } });
  const none = await codexClientOptions({ ...base, noTools: true }, {}, "/w/codex", servers([]).list);
  assert.deepEqual(none.config, { features, agents });
});

test("#codex-connectors codexClientOptions keeps the API key", async () => {
  const o = await codexClientOptions({ ...base, noTools: true }, { OPENAI_API_KEY: "sk-x" }, "/w/codex", servers([]).list);
  assert.equal(o.apiKey, "sk-x");
});

/// A stand-in Codex CLI: records its arguments and directory, then runs `body`.
function stubCli(body: string): { cli: string; argsFile: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "advisor-codex-cli-"));
  const cli = path.join(dir, "codex");
  const argsFile = path.join(dir, "args");
  fs.writeFileSync(cli, `#!/bin/sh\necho "$PWD $@" > '${argsFile}'\n${body}\n`, { mode: 0o755 });
  return { cli, argsFile };
}

test("#codex-connectors codexConfigServers lists the configured servers, leaving out plugins'", async () => {
  const { cli, argsFile } = stubCli(`echo '[{"name":"fff","enabled":true},{"name":"docs","enabled":false}]'`);
  const cwd = fs.realpathSync(os.tmpdir());
  assert.deepEqual(await codexConfigServers(cli, cwd), ["fff", "docs"]);
  assert.equal(fs.readFileSync(argsFile, "utf8").trim(), `${cwd} mcp list --json -c features.plugins=false`);
});

test("#codex-connectors a failed server listing fails the session", async () => {
  await assert.rejects(codexConfigServers(stubCli("echo broken >&2; exit 1").cli, os.tmpdir()), /broken/);
  await assert.rejects(codexConfigServers(stubCli("echo not-json").cli, os.tmpdir()));
});

test("#codex-connectors a listed server without a name fails the session", async () => {
  // Read as "undefined", it would pass the name check and disable nothing.
  const { cli } = stubCli(`echo '[{"name":"fff"},{"id":"docs"}]'`);
  await assert.rejects(codexConfigServers(cli, os.tmpdir()), /name/);
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
