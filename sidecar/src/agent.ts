import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { homedir } from "node:os";
import fs from "node:fs";
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

/// macOS's default filesystem is case-insensitive, so `~/.SSH/id_rsa` reaches
/// the same file as `~/.ssh/id_rsa`. Compare case-folded so a case variant can
/// never slip past the denylist. (Strictly safer than the FS: on a genuinely
/// case-sensitive volume this only ever denies more, never less.)
function isUnder(child: string, parent: string): boolean {
  const c = child.toLowerCase();
  const p = parent.toLowerCase();
  return c === p || c.startsWith(p + path.sep);
}

/// Resolve symlinks so the denylist sees the real target, not a link that
/// points into a denied dir (e.g. ~/Documents/x -> ~/.ssh). A purely lexical
/// check is bypassable by one symlink. realpathSync needs the path to exist, so
/// for a not-yet-existing leaf we resolve the deepest existing ancestor and
/// re-append the unresolved tail (which, not existing, can hold no symlinks).
function realResolve(abs: string, realpath: (p: string) => string): string {
  const tail: string[] = [];
  let cur = abs;
  for (;;) {
    try {
      return path.join(realpath(cur), ...[...tail].reverse());
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return abs; // reached root with nothing resolvable
      tail.push(path.basename(cur));
      cur = parent;
    }
  }
}

/// Read policy: any non-sensitive file at or under $HOME; nothing outside.
/// `realpath` is injectable for tests; production uses the real filesystem.
export function readPathAllowed(
  home: string,
  cwd: string,
  p: unknown,
  realpath: (p: string) => string = fs.realpathSync
): boolean {
  const r0 = resolveRoot(cwd, p);
  if (r0 === null) return false;
  const r = realResolve(r0, realpath);
  if (!isUnder(r, home)) return false;
  return !deniedPaths(home).some((d) => isUnder(r, d));
}

/// Search (Grep/Glob) policy: stricter than Read because these recurse — a
/// recursive pattern from an allowed root would otherwise reach secrets in a
/// denied descendant (e.g. Glob {path:$HOME, pattern:".ssh/**"} or
/// Grep {path:$HOME, pattern:"PRIVATE KEY"}). So validating the root path is not
/// enough: the root must also not sit at or above any denied path. This makes an
/// unscoped $HOME-rooted search illegal; agents must target a specific subtree.
export function searchRootAllowed(
  home: string,
  cwd: string,
  p: unknown,
  realpath: (p: string) => string = fs.realpathSync
): boolean {
  if (!readPathAllowed(home, cwd, p, realpath)) return false;
  const r = realResolve(resolveRoot(cwd, p)!, realpath);
  return !deniedPaths(home).some((d) => isUnder(d, r));
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
  /// Set when the turn failed/timed out/ended without a clean answer, so the
  /// caller can surface the reason instead of a generic "no answer" message.
  error?: string;
}

interface PendingTask {
  onText?: (accumulated: string) => void;
  resolve: (r: TaskResult) => void;
  settled: boolean;
  buffer: string;
  t0: number; // dispatch time, for latency logging
  cold: boolean; // first run after a (re)spawn pays the SDK subprocess boot
  firstTextLogged: boolean;
}

export interface AgentSessionOptions {
  name: string;
  systemPrompt: string;
  model?: string;
  allowedTools: string[];
  cwd?: string;
  /// SDK setting sources to load. Defaults to ["user"] (the user's own Claude
  /// config — CLAUDE.md, MCP, etc.), which the research/query lanes need for
  /// personal context. Pass [] for components that don't (e.g. the classifier,
  /// which only reads the transcript window) to avoid loading it on every turn.
  settingSources?: ("user" | "project" | "local")[];
  /// Allow MCP connector tools that take actions (send/create/...). Read/search
  /// connector tools are always allowed.
  allowMcpActions?: boolean;
}

/// The SDK entry point. Aliased so it can be injected (default: the real
/// `query`) — tests drive a fake stream to exercise the timeout/reset lifecycle
/// without spawning a subprocess (mirrors the injectable `realpath` above).
export type QueryFn = typeof query;

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

/// Connector action verbs — tools that can change external state. Matched as a
/// word (start, or after _ / -, ending at _ / - / end) in the bare tool name,
/// which is first normalised (`normaliseVerbName`) so a verb glued mid-camelCase
/// (`fetchAndDelete` → `fetch_and_delete`) becomes a delimited, lower-case word
/// the anchor can see — without that step such a verb is invisible and the name
/// fails OPEN via a leading read verb. The trailing `set` etc. only match a whole
/// word, so `settings`/`assets` never trip. Checked BEFORE the read allowlist so
/// a name carrying both an action and a read verb (e.g. `ddsql_upsert_saved_query`,
/// `searchAndUpdate`) is gated.
const MCP_ACTION_PATTERN =
  /(?:^|[_-])(send|post|create|update|upsert|delete|remove|write|upload|install|uninstall|add|run|exec|execute|start|stop|enable|disable|schedule|transition|invite|archive|publish|edit|move|rename|merge|close|cancel|assign|apply|approve|reject|import|export|reset|clear|drop|grant|revoke|set|authenticate|complete)(?:[_-]|[A-Z]|$)/;

/// Connector read/search verbs. Only consulted after the action check fails, so
/// it can be permissive (no trailing boundary) without re-opening the hole.
const MCP_READ_PATTERN =
  /(?:^|[_-])(get|list|search|read|fetch|lookup|view|find|describe|query|history|docs?|info|schema|aggregate|analy[sz]e|explore|expand|rank|recommend|summari[sz]e|visuali[sz]e|typecheck|diff|share)/;

/// The bare tool name after the `mcp__server__` prefix (so the server name can't
/// trip a verb match). Non-MCP names are returned unchanged.
function bareMcpName(toolName: string): string {
  const i = toolName.lastIndexOf("__");
  return i >= 0 ? toolName.slice(i + 2) : toolName;
}

/// Split camelCase into `_`-delimited words and lower-case, so the verb patterns'
/// `^ / _ / -` word anchors also see a verb embedded mid-camelCase. Without this,
/// `fetchAndDelete` hides `delete` behind a lower-case letter (no anchor) and,
/// being upper-cased, dodges the case-sensitive match too — so the action gate
/// misses it and a leading read verb (`fetch`) waves it through: a fail-OPEN.
function normaliseVerbName(name: string): string {
  return name.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase();
}

/// MCP connector permission. Fail closed: when actions are disabled a tool is
/// allowed only if it is recognised as a read/search. An action verb, OR any
/// name we don't recognise, is denied — a new mutating tool we've never seen is
/// blocked by default rather than waved through.
export function mcpPermission(toolName: string, allowMcpActions: boolean): "allow" | "deny" {
  if (allowMcpActions) return "allow";
  const name = normaliseVerbName(bareMcpName(toolName));
  if (MCP_ACTION_PATTERN.test(name)) return "deny";
  if (MCP_READ_PATTERN.test(name)) return "allow";
  return "deny";
}

/**
 * A long-lived Agent SDK session fed via streaming input. Avoids the ~5–10 s
 * CLI cold-spawn per request; each task is one (possibly multi-turn) exchange.
 * Tasks are answered strictly in FIFO order.
 */
export class AgentSession implements Agent {
  private input?: AsyncQueue<SDKUserMessage>;
  private pending: PendingTask[] = [];
  private firstRunAfterSpawn = false;

  constructor(
    private readonly opts: AgentSessionOptions,
    private readonly queryFn: QueryFn = query
  ) {}

  private stream?: ReturnType<typeof query>;

  /** Drop the session (and its accumulated context); next run() starts fresh. */
  reset(): void {
    this.input?.end();
    this.input = undefined;
    this.stream = undefined;
    // Detach the current queue from its (now-abandoned) stream loop and settle
    // anything still unresolved. Pooled lanes are recycled through here on a
    // timeout/error, so a turn that was interrupted but never emitted a `result`
    // can't leave its settled task at the queue head — where it would suppress
    // the next task's streaming (the `!current.settled` guard) or desync results
    // by mis-shifting a later `result` onto the wrong task (issue #46). The old
    // loop keeps draining its own captured queue (see ensure), so replacing the
    // reference here can't make two generations fight over one array.
    const orphaned = this.pending;
    this.pending = [];
    for (const p of orphaned) {
      if (!p.settled) {
        p.settled = true;
        p.resolve({ text: p.buffer, error: "agent session reset" });
      }
    }
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
    // A previous turn that timed out (or was interrupted) but never emitted a
    // clean `result` leaves its settled task at the head of the queue. Reusing
    // the session would let that stale head suppress this task's streaming and
    // mis-shift results, so recycle first (issue #46). The normal success path
    // shifts the task on `result`, leaving the queue empty — so the warm session
    // is preserved. This also recovers a wedged classifier or warm-up turn,
    // which settle via timeout but don't go through runCard's failure recycle.
    if (this.pending.some((p) => p.settled)) {
      log(`${this.opts.name}: recycling session (abandoned task at queue head)`);
      this.reset();
    }
    this.ensure();
    const cold = this.firstRunAfterSpawn;
    this.firstRunAfterSpawn = false;
    const p: PendingTask = {
      onText,
      resolve: () => {},
      settled: false,
      buffer: "",
      t0: Date.now(),
      cold,
      firstTextLogged: false,
    };
    log(`${this.opts.name}: run start (cold=${cold}, queue=${this.pending.length})`);
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
          // Stop the abandoned turn: without this it runs on (up to maxTurns),
          // burning cost off the books and queueing behind the next task.
          void this.interrupt();
          res({ text: p.buffer, error: "timed out" });
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
    // SDK MCP resource enumeration/read — pure reads, always allowed. (Both the
    // bare and `…Tool`-suffixed names the SDK may use.)
    if (toolName === "ListMcpResources" || toolName === "ReadMcpResource"
        || toolName === "ListMcpResourcesTool" || toolName === "ReadMcpResourceTool") {
      return allow;
    }
    // User-configured MCP connectors (Slack, Jira, ...): reads/searches allowed;
    // action tools only when enabled in preferences. Fail closed (mcpPermission).
    if (toolName.startsWith("mcp__")) {
      if (mcpPermission(toolName, this.opts.allowMcpActions ?? false) === "allow") return allow;
      log(`${this.opts.name}: denied MCP tool ${toolName}`);
      return {
        behavior: "deny",
        message:
          `${toolName} is not an allowed read/search connector tool. ` +
          `Advisor allows read/search connector tools only, unless "Allow connector actions" is enabled in Preferences.`,
      };
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
    log(`${this.opts.name}: spawning SDK subprocess (cold-start)`);
    this.firstRunAfterSpawn = true;
    const q = new AsyncQueue<SDKUserMessage>();
    this.input = q;
    // Give this spawn its own pending queue, captured by the loop below. After a
    // reset()/recycle the previous loop keeps draining this (now orphaned) array
    // while the next spawn gets a fresh one, so two generations never shift from
    // one shared queue (issue #46).
    const pending: PendingTask[] = [];
    this.pending = pending;
    const stream = this.queryFn({
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
        // Components that don't need it (the classifier) pass [] to skip it.
        settingSources: this.opts.settingSources ?? ["user"],
        maxTurns: 1000,
      },
    });
    this.stream = stream;
    void (async () => {
      try {
        for await (const msg of stream) {
          const current = pending[0];
          if (msg.type === "assistant") {
            for (const block of msg.message.content) {
              if (block.type === "text" && current && !current.settled) {
                // Log every text block (each card update) as a delta, so the
                // progression of what reaches the card is visible in the logs.
                const tag = current.firstTextLogged ? "text+" : "first text";
                current.firstTextLogged = true;
                log(`${this.opts.name}: ${tag} +${Date.now() - current.t0}ms: ${JSON.stringify(block.text.slice(0, 280))}`);
                current.buffer += (current.buffer ? "\n\n" : "") + block.text;
                current.onText?.(current.buffer);
              } else if (block.type === "tool_use") {
                log(`${this.opts.name}: tool ${block.name}`);
              }
            }
          } else if (msg.type === "result") {
            const p = pending.shift();
            if (p) {
              const finalText = msg.subtype === "success" ? msg.result : p.buffer;
              log(`${this.opts.name}: run done +${Date.now() - p.t0}ms (cold=${p.cold}) final: ${JSON.stringify((finalText ?? "").slice(0, 400))}`);
            }
            if (p && !p.settled) {
              p.settled = true;
              p.resolve({
                text: msg.subtype === "success" ? msg.result : p.buffer,
                error: msg.subtype === "success" ? undefined : msg.subtype,
              });
            }
          }
        }
      } catch (err) {
        log(`${this.opts.name}: session died: ${err}`);
      } finally {
        if (this.input === q) this.input = undefined;
        for (const p of pending.splice(0)) {
          if (!p.settled) {
            p.settled = true;
            p.resolve({ text: p.buffer, error: "agent session ended" });
          }
        }
      }
    })();
  }
}
