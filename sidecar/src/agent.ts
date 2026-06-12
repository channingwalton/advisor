import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import path from "node:path";
import { log } from "./protocol.js";

type PermissionResult =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string };

/** Unbounded async queue usable as the SDK's streaming prompt input. */
export class AsyncQueue<T> implements AsyncIterable<T> {
  private items: T[] = [];
  private resolvers: ((r: IteratorResult<T>) => void)[] = [];
  private done = false;

  push(item: T): void {
    const r = this.resolvers.shift();
    if (r) r({ value: item, done: false });
    else this.items.push(item);
  }

  end(): void {
    this.done = true;
    for (const r of this.resolvers.splice(0)) {
      r({ value: undefined as never, done: true });
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: (): Promise<IteratorResult<T>> => {
        if (this.items.length > 0) {
          return Promise.resolve({ value: this.items.shift()!, done: false });
        }
        if (this.done) return Promise.resolve({ value: undefined as never, done: true });
        return new Promise((res) => this.resolvers.push(res));
      },
    };
  }
}

export interface TaskResult {
  text: string;
  costUsd: number;
}

interface PendingTask {
  onText?: (accumulated: string) => void;
  resolve: (r: TaskResult) => void;
  settled: boolean;
  buffer: string;
}

export interface AgentSessionOptions {
  name: string;
  systemPrompt: string;
  model?: string;
  allowedTools: string[];
  cwd?: string;
  /// Directories Read/Grep/Glob may touch. Everything else is denied.
  readRoots?: string[];
}

/**
 * A long-lived Agent SDK session fed via streaming input. Avoids the ~5–10 s
 * CLI cold-spawn per request; each task is one (possibly multi-turn) exchange.
 * Tasks are answered strictly in FIFO order.
 */
export class AgentSession {
  private input?: AsyncQueue<SDKUserMessage>;
  private pending: PendingTask[] = [];
  /// total_cost_usd on result messages is cumulative per session; track the
  /// last value so each task reports its delta.
  private lastCostUsd = 0;

  constructor(private readonly opts: AgentSessionOptions) {}

  private stream?: ReturnType<typeof query>;

  /** Drop the session (and its accumulated context); next run() starts fresh. */
  reset(): void {
    this.input?.end();
    this.input = undefined;
  }

  /** Interrupt the currently-running turn (the task resolves with its partial buffer). */
  async interrupt(): Promise<void> {
    try {
      await this.stream?.interrupt();
    } catch (err) {
      log(`${this.opts.name}: interrupt failed: ${err}`);
    }
  }

  async run(
    task: string,
    onText?: (accumulated: string) => void,
    timeoutMs = 180_000
  ): Promise<TaskResult> {
    this.ensure();
    const p: PendingTask = { onText, resolve: () => {}, settled: false, buffer: "" };
    const answer = new Promise<TaskResult>((res) => {
      p.resolve = res;
    });
    this.pending.push(p);
    this.input!.push({
      type: "user",
      message: { role: "user", content: task },
      parent_tool_use_id: null,
      session_id: "",
    } as SDKUserMessage);

    const timeout = new Promise<TaskResult>((res) =>
      setTimeout(() => {
        if (!p.settled) {
          p.settled = true;
          log(`${this.opts.name}: task timed out`);
          res({ text: p.buffer, costUsd: 0 });
        }
      }, timeoutMs)
    );
    return Promise.race([answer, timeout]);
  }

  /// Sandbox policy: web tools allowed; Read/Grep/Glob only inside readRoots;
  /// everything else (Bash, Write, Edit, ...) denied.
  private canUseTool = async (
    toolName: string,
    input: Record<string, unknown>
  ): Promise<PermissionResult> => {
    const allow: PermissionResult = { behavior: "allow", updatedInput: input };
    switch (toolName) {
      case "WebSearch":
      case "WebFetch":
        return allow;
      case "Read":
        return this.pathAllowed(input.file_path) ? allow : this.denyPath(toolName, input.file_path);
      case "Grep":
      case "Glob":
        return this.pathAllowed(input.path) ? allow : this.denyPath(toolName, input.path);
      default:
        return { behavior: "deny", message: `${toolName} is not permitted in Advisor` };
    }
  };

  private pathAllowed(p: unknown): boolean {
    const roots = this.opts.readRoots ?? [];
    if (p === undefined || p === null || p === "") return true; // tool defaults to cwd (a root)
    if (typeof p !== "string") return false;
    const resolved = path.resolve(this.opts.cwd ?? "/", p);
    return roots.some((root) => resolved === root || resolved.startsWith(root + path.sep));
  }

  private denyPath(tool: string, p: unknown): PermissionResult {
    log(`${this.opts.name}: denied ${tool} on ${String(p)}`);
    return {
      behavior: "deny",
      message: `Access denied: ${tool} may only access ${this.opts.readRoots?.join(", ")}`,
    };
  }

  private ensure(): void {
    if (this.input) return;
    const q = new AsyncQueue<SDKUserMessage>();
    this.input = q;
    const stream = query({
      prompt: q,
      options: {
        // (stream kept for interrupt())
        systemPrompt: this.opts.systemPrompt,
        model: this.opts.model,
        // Auto-allowed tools (no permission check) — web only.
        allowedTools: this.opts.allowedTools.filter((t) => t.startsWith("Web")),
        disallowedTools: ["Bash", "Write", "Edit", "NotebookEdit", "Task", "KillShell"],
        cwd: this.opts.cwd,
        permissionMode: "default",
        canUseTool: this.canUseTool,
        maxTurns: 1000,
      },
    });
    this.stream = stream;
    void (async () => {
      try {
        for await (const msg of stream) {
          const current = this.pending[0];
          if (msg.type === "assistant") {
            for (const block of msg.message.content) {
              if (block.type === "text" && current && !current.settled) {
                current.buffer += (current.buffer ? "\n\n" : "") + block.text;
                current.onText?.(current.buffer);
              } else if (block.type === "tool_use") {
                log(`${this.opts.name}: tool ${block.name}`);
              }
            }
          } else if (msg.type === "result") {
            const p = this.pending.shift();
            const cumulative = "total_cost_usd" in msg ? (msg.total_cost_usd ?? 0) : 0;
            const delta = Math.max(0, cumulative - this.lastCostUsd);
            this.lastCostUsd = cumulative;
            if (p && !p.settled) {
              p.settled = true;
              p.resolve({
                text: msg.subtype === "success" ? msg.result : p.buffer,
                costUsd: delta,
              });
            }
          }
        }
      } catch (err) {
        log(`${this.opts.name}: session died: ${err}`);
      } finally {
        if (this.input === q) this.input = undefined;
        this.lastCostUsd = 0;
        for (const p of this.pending.splice(0)) {
          if (!p.settled) {
            p.settled = true;
            p.resolve({ text: p.buffer, costUsd: 0 });
          }
        }
      }
    })();
  }
}
