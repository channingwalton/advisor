import { homedir } from "node:os";
import { Codex, type Thread, type ThreadOptions } from "@openai/codex-sdk";
import type { Agent, AgentSessionOptions, TaskResult } from "./agent.js";
import { log } from "./protocol.js";

/// Map an Advisor agent spec onto Codex thread options.
///
/// Sandbox: "read-only" + "never" approval means the agent cannot write, edit,
/// run network-mutating commands, or escalate — it can only read and (when the
/// component uses web tools) search the web. Note this is coarser than the
/// Claude backend's per-path `canUseTool`: a read-only shell command could in
/// principle read sensitive dotfiles, and MCP servers come from the user's
/// ~/.codex/config.toml rather than being gated by `allowMcpActions`. See
/// DESIGN.md.
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

  constructor(private readonly opts: AgentSessionOptions) {}

  reset(): void {
    this.controller?.abort();
    this.thread = undefined;
    this.firstTurn = true;
  }

  async interrupt(): Promise<void> {
    this.controller?.abort();
  }

  private ensure(): Thread {
    if (!this.codex) this.codex = new Codex();
    if (!this.thread) this.thread = this.codex.startThread(codexThreadOptions(this.opts));
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

    const timeout = new Promise<TaskResult>((resolve) =>
      setTimeout(() => {
        if (!settled) {
          log(`${this.opts.name}: codex task timed out`);
          controller.abort();
          finish(resolve, "timed out");
        }
      }, timeoutMs)
    );

    return Promise.race([turn, timeout]);
  }
}
