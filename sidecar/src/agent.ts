import {
  query,
  type EffortLevel,
  type HookCallback,
  type SDKPartialAssistantMessage,
  type SDKResultMessage,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { homedir } from "node:os";
import fs from "node:fs";
import path from "node:path";
import { describeToolUse, THINKING } from "./activity.js";
import { log } from "./protocol.js";

type PermissionResult =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string };

const HOME = homedir();

/// The Claude agents' working directory: an empty folder of Advisor's own. The
/// CLI approves reads inside its working directory without consulting the
/// sandbox, so this must not be $HOME — the PreToolUse gate catches those reads
/// anyway; this keeps the implicit approval pointing at nothing. Created on
/// first spawn. (Codex keeps $HOME: its sandbox is the Seatbelt profile.)
export function agentCwd(home: string): string {
  return path.join(home, "Library", "Application Support", "Advisor", "agent-cwd");
}

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
/// Keep both lexical and resolved denied roots: a credential directory may
/// itself be a symlink (e.g. ~/.ssh -> ~/dotfiles/.ssh).
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
  return !deniedPaths(home).some((d) =>
    isUnder(r, d) || isUnder(r, realResolve(d, realpath))
  );
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
  return !deniedPaths(home).some((d) =>
    isUnder(d, r) || isUnder(realResolve(d, realpath), r)
  );
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

/// What a running task reports as it goes.
export interface RunProgress {
  /// The answer so far, each time it grows.
  onText?: (accumulated: string) => void;
  /// A short line saying what the agent is doing now, e.g. `Searching the web
  /// for “Cedar”` (see activity.ts).
  onActivity?: (activity: string) => void;
}

interface PendingTask {
  progress?: RunProgress;
  resolve: (r: TaskResult) => void;
  settled: boolean;
  buffer: string;
  t0: number; // dispatch time, for latency logging
  cold: boolean; // first run after a (re)spawn pays the SDK subprocess boot
  firstTextLogged: boolean;
  /// The message being streamed, until its `message_stop`, and the length of
  /// `buffer` before it — so its text can come off again if the CLI replaces it.
  open?: { id: string; mark: number };
  /// Messages whose text was streamed: their finished blocks are already in `buffer`.
  streamed: Set<string>;
  /// A text block has started but none of its text has arrived yet.
  blockOpen: boolean;
}

export interface AgentSessionOptions {
  name: string;
  systemPrompt: string;
  model?: string;
  /// How much the model thinks (SDK effort level). Unset = the CLI's own
  /// choice, which includes the user's `effortLevel` from their settings.
  effort?: EffortLevel;
  allowedTools: string[];
  /// Offer the model no built-in tools and no MCP servers — the user's own or
  /// their claude.ai connectors (the classifier, which only reads its prompt).
  /// An empty `allowedTools` doesn't do this: it only skips the permission
  /// check, and every other tool is still offered. A tool the user's settings
  /// switch on (`ENABLE_LSP_TOOL` adds LSP) still comes through, so pair it with
  /// `settingSources: []`. Codex can't remove every built-in tool (see
  /// `codexClientOptions`).
  noTools?: boolean;
  cwd?: string;
  /// SDK setting sources to load. Defaults to ["user"] (the user's own Claude
  /// config — CLAUDE.md, MCP, etc.), which the research/query lanes need for
  /// personal context. Pass [] for components that don't (e.g. the classifier,
  /// which only reads the transcript window) to avoid loading it on every turn.
  settingSources?: ("user" | "project" | "local")[];
  /// Allow MCP connector tools that take actions (send/create/...). Read/search
  /// connector tools are always allowed.
  allowMcpActions?: boolean;
  /// The home directory the sandbox policy is relative to. Defaults to the
  /// user's; injectable so tests can run the real CLI against a synthetic home.
  home?: string;
}

/// The SDK entry point. Aliased so it can be injected (default: the real
/// `query`) — tests drive a fake stream to exercise the timeout/reset lifecycle
/// without spawning a subprocess (mirrors the injectable `realpath` above).
export type QueryFn = typeof query;

/// A long-lived agent backend. Tasks are answered in FIFO order; the session
/// retains context across tasks until reset().
export interface Agent {
  run(task: string, progress?: RunProgress, timeoutMs?: number): Promise<TaskResult>;
  /** Drop the session (and its accumulated context); next run() starts fresh. */
  reset(): void;
  /** Interrupt the currently-running turn (best effort). */
  interrupt(): Promise<void>;
}

/// Connector action verbs — tools that can change external state — wherever
/// they sit in the tool name. Names reach the patterns normalised
/// (`normaliseVerbName`): lower-case words joined by `_`, so `_`/end are the
/// word boundaries and `set` never trips on `settings`/`assets`. Checked BEFORE
/// the read allowlist so a name carrying both an action and a read verb
/// (`ddsql_upsert_saved_query`, `searchAndUpdate`) is gated.
const MCP_ACTION_PATTERN =
  /(?:^|_)(send|post|create|update|upsert|delete|remove|write|upload|install|uninstall|add|run|exec|execute|start|stop|enable|disable|schedule|transition|invite|archive|publish|edit|move|rename|merge|close|cancel|assign|apply|approve|reject|import|export|reset|clear|drop|grant|revoke|set|authenticate|complete|replace|insert|append|submit|save|modify|put|purge|trash|wipe|sync|notify|acknowledge|trigger|subscribe|unsubscribe|restore|lock|unlock|toggle|pay|transfer|kill|terminate|destroy|revert|rotate|register|unregister|dismiss|escalate|refresh|regenerate|redeem|snooze|forward|convert|generate|compose|ban|mute|block|accept|decline|unfollow|migrate|truncate|flush|invalidate|rewrite|overwrite|undelete|prepend)(?:_|$)/;

/// Verbs that are also the nouns read tools are named after (`get_comment`,
/// `list_deploy_keys`, `get_share_link`, `get_open_issues`, `get_commit_patch`):
/// an action unless a read verb comes before them in the name — so
/// `comment_on_issue`, `share_file`, `mark_read` and the service-prefixed
/// `gmail_mark_as_read` are actions, `jira_get_issue_comment` is a read. Code
/// review 2026-10-17 — `share` had sat in the read list, and sharing grants a
/// third party access.
const MCP_AMBIGUOUS_ACTION_PATTERN =
  /(?:^|_)(comment|reply|mark|share|copy|duplicate|push|deploy|patch|open|commit|release|flag|star|pin|react|follow|resolve|checkout|draft|like|vote|tag)(?:_|$)/;

/// `x_and_y` does y, whatever x says: a conjunction denies the name outright,
/// so an action verb the lists above lack cannot ride in behind a read verb
/// (`find_and_replace`, `get_or_insert`, `fetch_and_purge`). Fail-closed, so a
/// read tool named with one (`search_public_and_private`) is refused too — the
/// recorded cost.
const MCP_CONJUNCTION_PATTERN = /_(and|or|then)_/;

/// Connector read/search verbs, anywhere in the name — connectors prefix their
/// tools with the service or entity (`slack_search_public`, `ddsql_query`).
/// Whole words (`listen` is not `list`). A verb on neither action list ahead of
/// one of these passes; the lists above are the defence against that, and
/// connector actions being off by default the backstop.
const MCP_READ_PATTERN =
  /(?:^|_)(get|list|search|read|fetch|lookup|view|find|describe|query|aggregate|analy[sz]e|explore|expand|rank|recommend|summari[sz]e|visuali[sz]e|typecheck|diff|shared)(?:_|$)/;

/// Nouns a tool is named after when it returns them: a read as the whole name
/// (`docs`) or its last word (`conversations_history`, `atlassian_user_info`,
/// `table_schema`, `schema_info`), so `purge_history`, `sync_schema` and
/// `schema_migrate` are judged by their verb, not waved through on the noun.
const MCP_READ_NOUN_PATTERN = /(?:^|_)(history|docs?|info|schema)$/;

/// The bare tool name after the `mcp__<server>__` prefix (so the server name
/// can't trip a verb match). The prefix ends at the first `__` after the server
/// name — a tool's own name may contain `__` too (`delete__list`), and taking
/// the last one would judge it on its final word alone. Non-MCP names are
/// returned unchanged.
export function bareMcpName(toolName: string): string {
  const m = /^mcp__.+?__(.*)$/.exec(toolName);
  return m ? m[1] : toolName;
}

/// Lower-case words joined by `_`, so the verb patterns' `^ / _` word anchors
/// see every word. camelCase splits (`fetchAndDelete` → `fetch_and_delete`:
/// without this, `delete` hides behind a lower-case letter and dodges the
/// case-sensitive match, so the action gate misses it and the leading `fetch`
/// waves it through — a fail-OPEN), an acronym run splits before its last
/// capital (`getHTTPPutURL` → `get_http_put_url`), and every other separator a
/// tool name may use (`-`, `.`, `/`, `:`, space) becomes `_`
/// (`search.delete` → `search_delete`), since a verb after one of those was
/// invisible to anchors that knew only `_` and `-`.
export function normaliseVerbName(name: string): string {
  return name
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1_$2")
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_");
}

/// MCP connector permission. Fail closed: when actions are disabled a tool is
/// allowed only if it is recognised as a read/search. An action verb, a
/// conjunction, OR any name we don't recognise, is denied — a new mutating tool
/// we've never seen is blocked by default rather than waved through.
export function mcpPermission(toolName: string, allowMcpActions: boolean): "allow" | "deny" {
  if (allowMcpActions) return "allow";
  const name = normaliseVerbName(bareMcpName(toolName));
  if (MCP_CONJUNCTION_PATTERN.test(name)) return "deny";
  if (MCP_ACTION_PATTERN.test(name)) return "deny";
  const read = MCP_READ_PATTERN.exec(name);
  const ambiguous = MCP_AMBIGUOUS_ACTION_PATTERN.exec(name);
  if (ambiguous && (!read || ambiguous.index < read.index)) return "deny";
  if (read) return "allow";
  if (MCP_READ_NOUN_PATTERN.test(name)) return "allow";
  return "deny";
}

/// Tools that need no path check. Everything else the CLI offers that isn't
/// Read/Grep/Glob or an MCP connector tool — Skill, Task*/Team*/Workflow, Cron*,
/// AskUserQuestion, worktrees, … — is refused. ToolSearch stays: it is how the CLI
/// loads deferred connector tools, so refusing it would cut agents off from MCP.
const OPEN_TOOLS = new Set([
  "WebSearch", "WebFetch", "ToolSearch",
  // SDK MCP resource enumeration/read — pure reads. (Both the bare and
  // `…Tool`-suffixed names the SDK may use.)
  "ListMcpResources", "ReadMcpResource", "ListMcpResourcesTool", "ReadMcpResourceTool",
]);

export interface SandboxPolicy {
  home: string;
  /// The CLI's working directory.
  cwd: string;
  allowMcpActions: boolean;
  /// Injectable for tests; production resolves symlinks on the real filesystem.
  realpath?: (p: string) => string;
}

export type ToolDecision = { behavior: "allow" } | { behavior: "deny"; message: string };

/// A path argument as the CLI will open it, or null when the policy can't be sure
/// which file that is. A leading `~` is the home directory, as the CLI expands it
/// (Read's before the gate; Glob/Grep's `path` reaches the gate unexpanded). A
/// relative path resolves against the CLI's cwd, so it is refused and the agent
/// retries with an absolute one.
function absolutePath(p: unknown, home: string): string | null {
  if (typeof p !== "string") return null;
  const expanded = p === "~" ? home : p.startsWith("~/") ? path.join(home, p.slice(2)) : p;
  return path.isAbsolute(expanded) ? expanded : null;
}

/// A Glob pattern (or Grep `glob` filter) that stays inside the root the policy
/// checked. The CLI searches an absolute pattern's own base directory instead of
/// `path`, so a permitted `path` with pattern `~/.ssh/*` listed the denied
/// directory (code review 2026-10-06). Refuse a pattern, or any brace
/// alternative of it (`{a, /etc/*}`), that starts with `/` or `~`, and any `..`
/// — the folder belongs in `path`. A `~` inside a name is literal (`*~`). Grep's
/// `glob` is optional (undefined passes).
function patternStaysInRoot(p: unknown): boolean {
  if (p === undefined) return true;
  if (typeof p !== "string") return false;
  return !(/(^|[{,])\s*[/~]/.test(p) || p.includes(".."));
}

/// The sandbox policy for one tool call. Shared by the PreToolUse gate and
/// canUseTool so the two can never disagree.
export function toolDecision(toolName: string, input: unknown, policy: SandboxPolicy): ToolDecision {
  const allow: ToolDecision = { behavior: "allow" };
  if (OPEN_TOOLS.has(toolName)) return allow;
  // User-configured MCP connectors (Slack, Jira, ...): reads/searches allowed;
  // action tools only when enabled in preferences. Fail closed (mcpPermission).
  if (toolName.startsWith("mcp__")) {
    return mcpPermission(toolName, policy.allowMcpActions) === "allow" ? allow : {
      behavior: "deny",
      message:
        `${toolName} is not an allowed read/search connector tool. ` +
        `Advisor allows read/search connector tools only, unless "Allow connector actions" is enabled in Preferences.`,
    };
  }
  const args = (input !== null && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const { home, cwd, realpath = fs.realpathSync } = policy;
  const deniedPath: ToolDecision = {
    behavior: "deny",
    message: `Access denied: ${toolName} needs an absolute path to a non-sensitive file or folder in the home directory`,
  };
  switch (toolName) {
    case "Read": {
      const file = absolutePath(args.file_path, home);
      return file !== null && readPathAllowed(home, cwd, file, realpath) ? allow : deniedPath;
    }
    case "Grep":
    case "Glob": {
      if (!patternStaysInRoot(toolName === "Glob" ? args.pattern : args.glob)) {
        return {
          behavior: "deny",
          message: `Access denied: ${toolName} patterns must be relative — no absolute, ~ or .. patterns. Put the folder in \`path\`.`,
        };
      }
      const root = absolutePath(args.path, home);
      return root !== null && searchRootAllowed(home, cwd, root, realpath) ? allow : deniedPath;
    }
    default:
      return { behavior: "deny", message: `${toolName} is not permitted in Advisor` };
  }
}

/// PreToolUse gate (code review 2026-10-06). The SDK approves some calls before
/// canUseTool is ever asked — reads inside its working directory, and allow rules
/// from the user's own settings (loaded via settingSources) — so a policy living
/// only in canUseTool was silently skipped for them. Hooks run first, and a hook
/// deny holds in every permission mode. Deny-only: a permitted call returns no
/// decision and continues through the normal flow, where canUseTool applies the
/// same policy again. Fails closed on any error.
export function sandboxGate(
  policy: SandboxPolicy,
  onDeny: (tool: string, input: unknown, message: string) => void = () => {},
  onAllow: (tool: string, input: unknown) => void = () => {}
): HookCallback {
  return async (input) => {
    if (input.hook_event_name !== "PreToolUse") return {};
    let decision: ToolDecision;
    try {
      decision = toolDecision(input.tool_name, input.tool_input, policy);
    } catch (err) {
      decision = { behavior: "deny", message: `Advisor sandbox error: ${err}` };
    }
    if (decision.behavior === "allow") {
      try {
        onAllow(input.tool_name, input.tool_input);
      } catch { /* reporting must not block the call */ }
      return {};
    }
    // A rejected hook is non-blocking for the CLI, so a logging failure must
    // not turn this deny into a pass.
    try {
      onDeny(input.tool_name, input.tool_input, decision.message);
    } catch { /* the deny still stands */ }
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: decision.message,
      },
    };
  };
}

/// A turn's result as the task sees it. A `success` result with `is_error` set
/// is how the SDK reports some failures — a logged-out CLI's "Not logged in ·
/// Please run /login" among them — with the message in `result`; read at face
/// value it reached the card as a finished answer (code review 2026-10-17). Text
/// the turn streamed before failing is kept, so the card can say it stopped
/// early (the CLI's synthetic echo of the message never reaches the buffer).
/// An error result names its subtype and, when the CLI gives one, its first
/// message. `result` is typed as a string but tolerated missing, as before.
/// The error goes onto the card as one italic line, so it is cut to its first
/// line and a bounded length: the CLI's messages can be JSON bodies or stacks.
export function resultOutcome(msg: SDKResultMessage, buffer: string): TaskResult {
  if (msg.subtype === "success") {
    const result = msg.result ?? "";
    if (!msg.is_error) return { text: result };
    return { text: buffer, error: oneLine(result) || "agent error" };
  }
  const detail = oneLine(msg.errors?.[0] ?? "");
  return { text: buffer, error: detail ? `${msg.subtype}: ${detail}` : msg.subtype };
}

/// A turn's token usage for the run-done log line. Per turn, unlike the
/// cumulative cost and API time on the same message. `out` counts thinking
/// too, so a short answer with a large `out` was thought over first.
function tokenUsage(msg: SDKResultMessage): string {
  const u = msg.usage as Partial<SDKResultMessage["usage"]> | undefined;
  if (!u) return "";
  return ` tokens in=${u.input_tokens} out=${u.output_tokens} cache_read=${u.cache_read_input_tokens} cache_write=${u.cache_creation_input_tokens}`;
}

const ERROR_LINE_MAX = 200;

function oneLine(s: string): string {
  const line = s.split("\n").map((l) => l.trim()).find((l) => l.length > 0) ?? "";
  return line.length > ERROR_LINE_MAX ? line.slice(0, ERROR_LINE_MAX - 1) + "…" : line;
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

  async run(task: string, progress?: RunProgress, timeoutMs = 180_000): Promise<TaskResult> {
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
    try {
      this.ensure();
    } catch (err) {
      // A failed turn, not a rejection, so callers' failure handling applies.
      log(`${this.opts.name}: could not start the agent: ${err}`);
      return { text: "", error: `could not start the agent: ${err}` };
    }
    const cold = this.firstRunAfterSpawn;
    this.firstRunAfterSpawn = false;
    const p: PendingTask = {
      progress,
      resolve: () => {},
      settled: false,
      buffer: "",
      t0: Date.now(),
      cold,
      firstTextLogged: false,
      streamed: new Set(),
      blockOpen: false,
    };
    log(`${this.opts.name}: run start (cold=${cold}, queue=${this.pending.length}, effort=${this.opts.effort ?? "default"})`);
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

    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<TaskResult>((res) => {
      timer = setTimeout(() => {
        if (!p.settled) {
          p.settled = true;
          log(`${this.opts.name}: task timed out`);
          // Stop the abandoned turn: without this it runs on (up to maxTurns),
          // burning cost off the books and queueing behind the next task.
          void this.interrupt();
          res({ text: p.buffer, error: "timed out" });
        }
      }, timeoutMs);
    });
    // Clear the timer once the race settles so a completed task doesn't retain
    // its PendingTask closure + buffer until the timeout fires (issue #56).
    return Promise.race([answer, timeout]).finally(() => clearTimeout(timer));
  }

  /// The sandbox policy (toolDecision) for this session's working directory.
  private get policy(): SandboxPolicy {
    return {
      home: this.opts.home ?? HOME,
      cwd: this.opts.cwd ?? agentCwd(this.opts.home ?? HOME),
      allowMcpActions: this.opts.allowMcpActions ?? false,
    };
  }

  /// A path or URL argument says what was refused; any other argument (Grep's
  /// `pattern` is a content search, a connector's are anything) can quote the
  /// conversation and stays out of the log.
  private logDenied = (tool: string, input: unknown, message: string): void => {
    const args = input !== null && typeof input === "object" ? (input as Record<string, unknown>) : {};
    const where = ["file_path", "path", "url", "glob", ...(tool === "Glob" ? ["pattern"] : [])]
      .filter((k) => typeof args[k] === "string")
      .map((k) => `${k}=${JSON.stringify(args[k])}`)
      .join(" ");
    log(`${this.opts.name}: denied ${tool}${where ? ` ${where}` : ""}: ${message}`);
  };

  /// The first text a task shows: the time a card stops being blank.
  private logFirstText(p: PendingTask): void {
    if (p.firstTextLogged) return;
    p.firstTextLogged = true;
    log(`${this.opts.name}: first text +${Date.now() - p.t0}ms`);
  }

  /// Take the text of a message that never finished back off the card: the CLI
  /// has replaced it (it removes the partial message from its own transcript).
  private dropOpen(p: PendingTask): void {
    if (!p.open) return;
    const { mark } = p.open;
    p.open = undefined;
    if (p.buffer.length === mark) return;
    log(`${this.opts.name}: dropping ${p.buffer.length - mark} chars of a message the CLI replaced`);
    p.buffer = p.buffer.slice(0, mark);
    p.progress?.onText?.(p.buffer);
  }

  /// A raw Messages API event from the main agent: text deltas grow the
  /// answer; a thinking block says so on the card.
  private onStreamEvent(p: PendingTask, ev: SDKPartialAssistantMessage["event"]): void {
    if (ev.type === "message_start") {
      // One still open broke off, and this is the CLI's retry of it.
      this.dropOpen(p);
      p.open = { id: ev.message.id, mark: p.buffer.length };
    } else if (ev.type === "message_stop") {
      p.open = undefined;
    } else if (ev.type === "content_block_start") {
      if (ev.content_block.type === "text") p.blockOpen = true;
      else if (ev.content_block.type === "thinking" || ev.content_block.type === "redacted_thinking") {
        p.progress?.onActivity?.(THINKING);
      }
    } else if (ev.type === "content_block_delta" && ev.delta.type === "text_delta" && ev.delta.text) {
      // Blocks are separated as whole ones are (see the assistant case).
      if (p.blockOpen && p.buffer) p.buffer += "\n\n";
      p.blockOpen = false;
      if (p.open) p.streamed.add(p.open.id);
      this.logFirstText(p);
      p.buffer += ev.delta.text;
      p.progress?.onText?.(p.buffer);
    }
  }

  /// Second check after the PreToolUse gate, for the calls the SDK asks about.
  private canUseTool = async (
    toolName: string,
    input: Record<string, unknown>
  ): Promise<PermissionResult> => {
    const decision = toolDecision(toolName, input, this.policy);
    if (decision.behavior === "allow") return { behavior: "allow", updatedInput: input };
    this.logDenied(toolName, input, decision.message);
    return decision;
  };

  private ensure(): void {
    if (this.input) return;
    // The CLI can't spawn in a missing folder (agentCwd is created on first
    // use). A failure here fails this run (see run()), not the sidecar's startup.
    fs.mkdirSync(this.policy.cwd, { recursive: true });
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
        effort: this.opts.effort,
        // Auto-allowed tools (no permission check) — web only.
        allowedTools: this.opts.allowedTools.filter((t) => t.startsWith("Web")),
        disallowedTools: ["Bash", "Write", "Edit", "NotebookEdit", "Task", "KillShell"],
        // No built-in tools, and only the MCP servers passed here (none) — not
        // the user's own or their claude.ai connectors.
        ...(this.opts.noTools ? { tools: [], mcpServers: {}, strictMcpConfig: true } : {}),
        cwd: this.policy.cwd,
        permissionMode: "default",
        // The sandbox: the gate runs before the SDK's own approvals; canUseTool
        // re-checks the calls the SDK asks about.
        // Only a call the gate lets through shows on the card.
        hooks: { PreToolUse: [{ hooks: [sandboxGate(this.policy, this.logDenied, (tool, input) => {
          const line = describeToolUse(tool, input);
          const current = pending[0];
          if (line && current && !current.settled) current.progress?.onActivity?.(line);
        })] }] },
        canUseTool: this.canUseTool,
        // Load the user's own Claude configuration (CLAUDE.md etc.) — that is
        // where personal context like vault locations belongs, not in Advisor.
        // Components that don't need it (the classifier) pass [] to skip it.
        settingSources: this.opts.settingSources ?? ["user"],
        // A research/query turn realistically needs a handful of search/fetch/read
        // rounds; a ceiling in the tens bounds a looping or prompt-injected agent's
        // tool-call/cost burn. The 180 s task timeout is the primary bound — this
        // is the secondary guard against a tight loop within it (issue #58).
        maxTurns: 40,
        // Text deltas as the model writes, so a card fills in word by word
        // rather than one whole block at the end of the turn.
        includePartialMessages: true,
        // Without this the CLI's stderr is dropped and a spawn-time crash
        // surfaces only as "exited with code 1" (the v0.2.0 DMG entitlement
        // break was invisible for exactly this reason). Per line, not per
        // chunk: a crash dump arrives as one multi-KB chunk with the actual
        // error at the end — a chunk-level cap would log only its prefix.
        stderr: (data: string) => {
          for (const raw of data.split("\n")) {
            const line = raw.trim();
            if (line) log(`${this.opts.name}: cli stderr: ${line.slice(0, 400)}`);
          }
        },
      },
    });
    this.stream = stream;
    let cause: string | undefined;
    void (async () => {
      try {
        for await (const msg of stream) {
          const current = pending[0];
          if (msg.type === "stream_event") {
            if (current && !current.settled && msg.parent_tool_use_id === null) this.onStreamEvent(current, msg.event);
          } else if (msg.type === "assistant") {
            // The CLI's own words, not the model's: a failure's message echoed as
            // an assistant block ("Not logged in · Please run /login") flagged
            // with the failure. The result that follows carries it as the error;
            // it is not answer text. (`max_output_tokens` marks real model text
            // that was cut off, which is.)
            if (msg.error !== undefined && msg.error !== "max_output_tokens") {
              log(`${this.opts.name}: assistant message flagged ${msg.error} skipped`);
              continue;
            }
            // Its text was already added delta by delta, unless it wasn't streamed.
            const streamed = current?.streamed.has(msg.message.id) ?? false;
            // A message the stream never announced, while another is still open:
            // the CLI's non-streaming fallback, replacing the one that broke off.
            if (current && !current.settled && !streamed && msg.parent_tool_use_id === null
                && current.open && current.open.id !== msg.message.id) {
              this.dropOpen(current);
            }
            for (const block of msg.message.content) {
              if (block.type === "text" && current && !current.settled) {
                // Log every finished text block, so the progression of what
                // reaches the card is visible in the logs.
                log(`${this.opts.name}: text+ +${Date.now() - current.t0}ms: ${JSON.stringify(block.text.slice(0, 280))}`);
                if (!streamed) {
                  this.logFirstText(current);
                  current.buffer += (current.buffer ? "\n\n" : "") + block.text;
                  current.progress?.onText?.(current.buffer);
                }
              } else if (block.type === "tool_use") {
                log(`${this.opts.name}: tool ${block.name}`);
              }
            }
          } else if (msg.type === "result") {
            const p = pending.shift();
            const outcome = resultOutcome(msg, p?.buffer ?? "");
            if (p) {
              log(`${this.opts.name}: run done +${Date.now() - p.t0}ms (cold=${p.cold})${tokenUsage(msg)} final: ${JSON.stringify(outcome.text.slice(0, 400))}${outcome.error ? ` error: ${outcome.error}` : ""}`);
            }
            if (p && !p.settled) {
              p.settled = true;
              p.resolve(outcome);
            }
            // After a flagged result the CLI may exit (no credentials: it does,
            // within ~100 ms, and the SDK then rethrows the result) or carry on
            // (an API 400 such as "prompt is too long": it answers the next
            // prompt). The session is kept either way: `finally` below drops a
            // dead one, and dropping a live one would cold-spawn the classifier
            // on every recoverable error.
          }
        }
      } catch (err) {
        log(`${this.opts.name}: session died: ${err}`);
        cause = err instanceof Error ? err.message : String(err);
      } finally {
        if (this.input === q) this.input = undefined;
        for (const p of pending.splice(0)) {
          if (!p.settled) {
            p.settled = true;
            // Name the cause: a missing or crashing CLI otherwise reaches the
            // card as a bare "agent session ended", its reason in stderr alone.
            p.resolve({ text: p.buffer, error: cause ? `agent session ended: ${cause}` : "agent session ended" });
          }
        }
      }
    })();
  }
}
