import { test } from "node:test";
import assert from "node:assert/strict";
import type { Thread } from "@openai/codex-sdk";
import { CodexAgentSession, codexConstructorOptions, codexThreadOptions } from "./codex.js";

const base = { name: "x", systemPrompt: "sp", allowedTools: [] as string[] };

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
