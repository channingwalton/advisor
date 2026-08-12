import { homedir } from "node:os";
import { Codex, type CodexOptions, type Thread, type ThreadOptions } from "@openai/codex-sdk";
import type { Agent, AgentSessionOptions, TaskResult } from "./agent.js";
import { codexSandboxWrapper } from "./codexSandbox.js";
import { log } from "./protocol.js";

/// Codex client auth. With an explicit `apiKey` the SDK talks to the OpenAI API
/// directly; without one it falls back to the user's Codex CLI login
/// (`~/.codex/auth.json`). The app injects `OPENAI_API_KEY` into the sidecar's
/// environment only when "API key" auth is selected, so its mere presence is the
/// signal to use it — passing it explicitly beats a stale ChatGPT login that
/// would otherwise win. `env` is left unset so the Codex CLI still inherits
/// `process.env` (MCP servers, PATH, …).
export function codexConstructorOptions(
  env: NodeJS.ProcessEnv,
  codexPathOverride?: string
): CodexOptions {
  const apiKey = env.OPENAI_API_KEY;
  return {
    ...(apiKey ? { apiKey } : {}),
    ...(codexPathOverride ? { codexPathOverride } : {}),
  };
}

/// Map an Advisor agent spec onto Codex thread options.
///
/// Sandbox: "read-only" + "never" approval is the CLI's own bound, kept as a
/// first layer but not relied on. It restricts modification, not reading (see
/// DESIGN.md), and MCP tools bypass it entirely (openai/codex#4152). The
/// enforced boundary is the Seatbelt profile the CLI runs under — see
/// codexSandbox.ts — which denies the same paths as the Claude backend's
/// `canUseTool` and confines writes, for the CLI and every process it spawns.
/// This is still coarser than `canUseTool`: MCP servers come from the user's
/// ~/.codex/config.toml and are not gated by `allowMcpActions`, so a connector
/// read the Claude backend would refuse can still happen here.
export function codexThreadOptions(opts: AgentSessionOptions): ThreadOptions {
  const web = opts.allowedTools.some((t) => t.startsWith("Web"));
  return {
    model: opts.model,
    sandboxMode: "read-only",
    approvalPolicy: "never",
    skipGitRepoCheck: true,
    workingDirectory: opts.cwd ?? homedir(),
    webSearchEnabled: web,
    networkAccessEnabled: web,
  };
}

/**
 * A long-lived Codex thread fed one task at a time. Mirrors AgentSession's
 * contract: run() resolves with the answer text (or "" on failure) and never
 * throws; the thread retains context across tasks until reset().
 *
 * Codex has no system-prompt parameter, so the configured system prompt is
 * prepended to the first turn; later turns inherit it from thread context.
 */
export class CodexAgentSession implements Agent {
  private codex?: Codex;
  private thread?: Thread;
  private firstTurn = true;
  private controller?: AbortController;

  constructor(
    private readonly opts: AgentSessionOptions,
    private readonly threadFactory?: (options: ThreadOptions) => Thread
  ) {}

  reset(): void {
    this.controller?.abort();
    this.thread = undefined;
    this.firstTurn = true;
  }

  async interrupt(): Promise<void> {
    this.controller?.abort();
  }

  private ensure(): Thread {
    if (!this.thread) {
      if (this.threadFactory) {
        this.thread = this.threadFactory(codexThreadOptions(this.opts));
      } else {
        // Spawn the CLI through Advisor's Seatbelt wrapper. Throws if the
        // sandbox cannot be installed — guardedRun turns that into a visible
        // error card, which is the right outcome: an unsandboxed Codex would
        // read every secret in $HOME and, via MCP tools that bypass its own
        // `read-only` mode (openai/codex#4152), write anywhere too.
        if (!this.codex) {
          this.codex = new Codex(codexConstructorOptions(process.env, codexSandboxWrapper()));
        }
        this.thread = this.codex.startThread(codexThreadOptions(this.opts));
      }
    }
    return this.thread;
  }

  async run(
    task: string,
    onText?: (accumulated: string) => void,
    timeoutMs = 180_000
  ): Promise<TaskResult> {
    const thread = this.ensure();
    const input = this.firstTurn ? `${this.opts.systemPrompt}\n\n${task}` : task;
    this.firstTurn = false;

    const controller = new AbortController();
    this.controller = controller;
    // Accumulate agent_message items by id: a turn can emit more than one, and
    // each item.updated carries that item's full text so far. Keying by id means
    // streaming updates overwrite their own item while distinct items concatenate
    // (the old `buffer = ev.item.text` dropped all but the last).
    const messages = new Map<string, string>();
    const joined = (): string => [...messages.values()].join("\n\n");
    let settled = false;
    const finish = (resolve: (r: TaskResult) => void, error?: string): void => {
      if (settled) return;
      settled = true;
      resolve({ text: joined(), error });
    };

    const turn = new Promise<TaskResult>((resolve) => {
      void (async () => {
        try {
          const { events } = await thread.runStreamed(input, { signal: controller.signal });
          for await (const ev of events) {
            if (ev.type === "item.updated" || ev.type === "item.completed") {
              if (ev.item.type === "agent_message") {
                messages.set(ev.item.id, ev.item.text);
                onText?.(joined());
              }
            } else if (ev.type === "turn.failed") {
              throw new Error(ev.error.message);
            } else if (ev.type === "error") {
              throw new Error(ev.message);
            }
          }
          finish(resolve);
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          if (!controller.signal.aborted) {
            log(`${this.opts.name}: codex turn failed: ${err}`);
            // Drop the (possibly dead) thread so the next task starts fresh and
            // re-sends the system prompt, mirroring the Claude backend.
            this.thread = undefined;
            this.firstTurn = true;
            finish(resolve, message);
          } else {
            finish(resolve);
          }
        }
      })();
    });

    let timeoutHandle!: NodeJS.Timeout;
    const timeout = new Promise<TaskResult>((resolve) => {
      timeoutHandle = setTimeout(() => {
        if (!settled) {
          log(`${this.opts.name}: codex task timed out`);
          controller.abort();
          finish(resolve, "timed out");
        }
      }, timeoutMs);
    });
    timeoutHandle.unref();

    try {
      return await Promise.race([turn, timeout]);
    } finally {
      // Do not retain this run or let a later reset abort its completed process.
      clearTimeout(timeoutHandle);
      if (this.controller === controller) this.controller = undefined;
    }
  }
}
