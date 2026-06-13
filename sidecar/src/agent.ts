import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { homedir } from "node:os";
import path from "node:path";
import { log } from "./protocol.js";

type PermissionResult =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string };

const HOME = homedir();

/// Paths (relative to $HOME) the agents may never read, even inside $HOME.
const DENY_NAMES = [
  ".ssh",
  ".aws",
  ".gnupg",
  ".claude",
  ".claude.json",
  ".npmrc",
  ".netrc",
  ".git-credentials",
  ".docker",
  ".kube",
  ".codex", // Codex provider creds/config (auth.json, config.toml)
  ".codex-global-state.json", // Codex global state (tokens)
  ".config/gh",
  "Library/Keychains",
  "Library/Cookies",
];

export function deniedPaths(home: string): string[] {
  return DENY_NAMES.map((p) => path.join(home, p));
}

/// Resolve a tool path argument to an absolute root. undefined/null/"" means the
/// tool defaults to cwd; a non-string is invalid (null).
function resolveRoot(cwd: string, p: unknown): string | null {
  if (p === undefined || p === null || p === "") return cwd;
  if (typeof p !== "string") return null;
  return path.resolve(cwd, p);
}

/// Read policy: any non-sensitive file at or under $HOME; nothing outside.
export function readPathAllowed(home: string, cwd: string, p: unknown): boolean {
  const r = resolveRoot(cwd, p);
  if (r === null) return false;
  if (r !== home && !r.startsWith(home + path.sep)) return false;
  return !deniedPaths(home).some((d) => r === d || r.startsWith(d + path.sep));
}

/// Search (Grep/Glob) policy: stricter than Read because these recurse — a
/// recursive pattern from an allowed root would otherwise reach secrets in a
/// denied descendant (e.g. Glob {path:$HOME, pattern:".ssh/**"} or
/// Grep {path:$HOME, pattern:"PRIVATE KEY"}). So validating the root path is not
/// enough: the root must also not sit at or above any denied path. This makes an
/// unscoped $HOME-rooted search illegal; agents must target a specific subtree.
export function searchRootAllowed(home: string, cwd: string, p: unknown): boolean {
  if (!readPathAllowed(home, cwd, p)) return false;
  const r = resolveRoot(cwd, p)!;
  return !deniedPaths(home).some((d) => d === r || d.startsWith(r + path.sep));
}

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
  /// Allow MCP connector tools that take actions (send/create/...). Read/search
  /// connector tools are always allowed.
  allowMcpActions?: boolean;
}

/// A long-lived agent backend. Tasks are answered in FIFO order; the session
/// retains context across tasks until reset().
export interface Agent {
  run(
    task: string,
    onText?: (accumulated: string) => void,
    timeoutMs?: number
  ): Promise<TaskResult>;
  /** Drop the session (and its accumulated context); next run() starts fresh. */
  reset(): void;
  /** Interrupt the currently-running turn (best effort). */
  interrupt(): Promise<void>;
}

/// MCP tool names that mutate external state.
const MCP_ACTION_PATTERN =
  /(send|post|create|update|delete|remove|write|upload|schedule|transition|invite|archive|publish|edit|move|rename|merge|close|assign|set[_A-Z])/i;

/**
 * A long-lived Agent SDK session fed via streaming input. Avoids the ~5–10 s
 * CLI cold-spawn per request; each task is one (possibly multi-turn) exchange.
 * Tasks are answered strictly in FIFO order.
 */
export class AgentSession implements Agent {
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
    // User-configured MCP connectors (Slack, Jira, ...): reads/searches allowed;
    // action tools only when enabled in preferences.
    if (toolName.startsWith("mcp__") || toolName === "ListMcpResources"
        || toolName === "ReadMcpResource") {
      if (MCP_ACTION_PATTERN.test(toolName) && !this.opts.allowMcpActions) {
        log(`${this.opts.name}: denied MCP action ${toolName}`);
        return {
          behavior: "deny",
          message:
            `${toolName} looks like an action (it can change external state). ` +
            `Advisor allows read/search connector tools only, unless "Allow connector actions" is enabled in Preferences.`,
        };
      }
      return allow;
    }
    switch (toolName) {
      case "WebSearch":
      case "WebFetch":
        return allow;
      case "Read":
        return readPathAllowed(HOME, this.opts.cwd ?? HOME, input.file_path)
          ? allow
          : this.denyPath(toolName, input.file_path);
      case "Grep":
      case "Glob":
        return searchRootAllowed(HOME, this.opts.cwd ?? HOME, input.path)
          ? allow
          : this.denyPath(toolName, input.path);
      default:
        return { behavior: "deny", message: `${toolName} is not permitted in Advisor` };
    }
  };

  private denyPath(tool: string, p: unknown): PermissionResult {
    log(`${this.opts.name}: denied ${tool} on ${String(p)}`);
    return {
      behavior: "deny",
      message: `Access denied: ${tool} may only read non-sensitive files in the home directory`,
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
        // Load the user's own Claude configuration (CLAUDE.md etc.) — that is
        // where personal context like vault locations belongs, not in Advisor.
        settingSources: ["user"],
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
