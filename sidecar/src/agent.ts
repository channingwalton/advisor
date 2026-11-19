import {
  query,
  type EffortLevel,
  type HookCallback,
  type SDKPartialAssistantMessage,
  type SDKResultMessage,
  type SDKUserMessage,
  type SpawnedProcess,
  type SpawnOptions,
} from "@anthropic-ai/claude-agent-sdk";
import { homedir } from "node:os";
import fs from "node:fs";
import path from "node:path";
import { describeToolUse, THINKING } from "./activity.js";
import { claudeSandboxProfile, claudeWriteFolders, spawnClaudeSandboxed } from "./claudeSandbox.js";
import { log } from "./protocol.js";
import {
  honouredFolders, readableFoldersNote, readableRoots, REALPATH, toolDecision, type SandboxPolicy, type ToolDecision,
} from "./toolPolicy.js";

type PermissionResult =
  | { behavior: "allow"; updatedInput: Record<string, unknown> }
  | { behavior: "deny"; message: string };

const HOME = homedir();

/// The Claude CLI runs under a Seatbelt profile on macOS (`claudeSandbox.ts`).
/// CI runs the sidecar on Linux, which has no Seatbelt: there the CLI starts as
/// the SDK starts it.
const SEATBELT = process.platform === "darwin";

/// The Claude agents' working directory: an empty folder of Advisor's own. The
/// CLI approves reads inside its working directory without consulting the
/// sandbox, so this must not be $HOME — the PreToolUse gate catches those reads
/// anyway; this keeps the implicit approval pointing at nothing. Created on
/// first spawn. Codex runs here too (`codexWorkingDirectory`).
export function agentCwd(home: string): string {
  return path.join(home, "Library", "Application Support", "Advisor", "agent-cwd");
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
  /// Set when the session discarded its conversation without an error (a
  /// stopped Codex turn drops its thread, #112), so the caller resends what
  /// that conversation held. An error already means the session starts again.
  contextLost?: boolean;
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
  /// The folders that Read, Grep and Glob may reach (`readableRoots`), read
  /// again at each call, so a folder that the user removes is refused at once.
  /// None by default. The CLI's Seatbelt profile takes the list when the CLI
  /// starts (`spawnSandboxed`). On Codex, a session with it gets Advisor's own
  /// file tools and their note (`codexClientOptions`, `codexFilesNote`); the
  /// Codex backend writes its profile and the tools' folder list from
  /// config.json before each turn (`refreshCodexSandbox`).
  readableFolders?: () => readonly string[];
  /// The session folder while the agents may read past sessions, else null
  /// (issue #154). Read at each task, for the note only: the folder reaches
  /// the policy through `readableFolders`.
  pastSessions?: () => string | null;
}

/// The SDK entry point. Aliased so it can be injected (default: the real
/// `query`) — tests drive a fake stream to exercise the timeout/reset lifecycle
/// without spawning a subprocess (mirrors the injectable `realpath` of toolPolicy.ts).
export type QueryFn = typeof query;

/// A long-lived agent backend. Tasks are answered in FIFO order; the session
/// retains context across tasks until reset().
export interface Agent {
  /// `recap` is what the session's conversation held before this task. The
  /// session puts it before the task only when the task starts a new
  /// conversation: a new, reset or dead Claude session, a Claude session
  /// recycled after a wedged turn (#46), or a new Codex thread. A session that
  /// keeps its conversation leaves it out (#116).
  run(task: string, progress?: RunProgress, timeoutMs?: number, recap?: string): Promise<TaskResult>;
  /** Drop the session (and its accumulated context); next run() starts fresh. */
  reset(): void;
  /** Interrupt the currently-running turn (best effort). */
  interrupt(): Promise<void>;
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
  /// The readable folders that the running CLI's Seatbelt profile allows, as
  /// listed, and as one string (`readableKey`). Recorded when the session
  /// starts a CLI, before the SDK calls the spawn hook, so the profile, this
  /// record and the next note agree.
  private spawnedList?: readonly string[];
  private spawnedRoots?: ReadonlySet<string>;
  private spawnedFolders?: string;

  constructor(
    private readonly opts: AgentSessionOptions,
    private readonly queryFn: QueryFn = query
  ) {}

  private stream?: ReturnType<typeof query>;

  /** Drop the session (and its accumulated context); next run() starts fresh. */
  reset(): void {
    const stream = this.stream;
    this.input?.end();
    this.input = undefined;
    this.stream = undefined;
    // Ending the input is not enough: in the real-CLI test, the CLI of a
    // blocked turn stayed after it (#142, `agent.close.sdk.test.ts`). close()
    // ends the CLI and the stream, so the old loop ends by itself.
    try {
      stream?.close();
    } catch (err) {
      log(`${this.opts.name}: close failed: ${err}`);
    }
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

  async run(task: string, progress?: RunProgress, timeoutMs = 180_000, recap?: string): Promise<TaskResult> {
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
    // The CLI's Seatbelt profile is fixed when it starts. After a change to
    // the readable folders, an idle session starts a new CLI, so that a folder
    // that the user adds can be read. The recap replays the transcript, not
    // the lane's own earlier answers, as after any recycle. A busy session
    // keeps its CLI until it is idle (decided 2026-11-11).
    if (this.input && this.pending.length === 0 && this.spawnedFolders !== undefined
        && this.spawnedFolders !== this.readableKey()) {
      log(`${this.opts.name}: readable folders changed; starting a new CLI`);
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
    // The first task after a spawn starts the conversation, so it carries the
    // recap. A recycle or a dead CLI spawns again (ensure), so it counts too.
    if (cold && recap) log(`${this.opts.name}: new conversation, recap ${recap.length} chars`);
    // A session that reads local files starts each task with the folders that
    // it can read now (`readableFoldersNote`): a warm session outlives a
    // change to the list, so its system prompt cannot hold it.
    const note = this.opts.readableFolders ? `${readableFoldersNote(this.policy.home, this.readableNow(), REALPATH, this.opts.pastSessions?.() ?? null)}\n\n` : "";
    this.input!.push({
      type: "user",
      message: { role: "user", content: note + (cold && recap ? recap + task : task) },
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

  /// The CLI's stderr, to the log. Without this the CLI's stderr is dropped
  /// and a spawn-time crash surfaces only as "exited with code 1" (the v0.2.0
  /// DMG entitlement break was invisible for exactly this reason). Per line,
  /// not per chunk: a crash dump arrives as one multi-KB chunk with the actual
  /// error at the end — a chunk-level cap would log only its prefix.
  private logStderr = (data: string): void => {
    for (const raw of data.split("\n")) {
      const line = raw.trim();
      if (line) log(`${this.opts.name}: cli stderr: ${line.slice(0, 400)}`);
    }
  };

  /// The folders that the agent can read now: those listed now that the
  /// running CLI's Seatbelt profile also allows. A folder added while the
  /// session is busy is left out until a new CLI starts, so the note never
  /// names a folder that the kernel refuses (code review 2026-11-11).
  /// A folder is judged by its resolved forms, not by its spelling: `~/Notes`
  /// and its absolute path are the same grant.
  private readableNow(): readonly string[] {
    const now = this.opts.readableFolders?.() ?? [];
    const roots = this.spawnedRoots;
    if (!roots) return now;
    return honouredFolders(this.policy.home, now, REALPATH)
      .filter((h) => h.forms.every((form) => roots.has(form)))
      .map((h) => h.folder);
  }

  /// The readable folders as the policy honours them now, as one string.
  private readableKey(): string {
    return JSON.stringify(readableRoots(this.policy.home, this.opts.readableFolders?.() ?? []));
  }

  /// Start the CLI under a Seatbelt profile of its own (GHSA-6xc8-f55f-jxqr,
  /// fault 2): the kernel holds the CLI and its stdio connectors to the
  /// readable folders, behind the tool gate. The subscription login needs the
  /// keychain; an API key, which the app passes in the environment, does not.
  /// The CLI writes only its transcripts and its connectors' logs in the home
  /// folder, in folders that it cannot create under the profile, so they are
  /// created here. Without them the CLI still answers, but keeps no
  /// transcript.
  private spawnSandboxed = (o: SpawnOptions): SpawnedProcess => {
    const { home } = this.policy;
    const cwd = o.cwd ?? this.policy.cwd;
    // The CLI takes an empty value as unset (`CLAUDE_CONFIG_DIR || homedir()`).
    const configDir = o.env.CLAUDE_CONFIG_DIR || undefined;
    for (const dir of claudeWriteFolders(home, cwd, configDir)) {
      try {
        fs.mkdirSync(dir, { recursive: true });
      } catch (err) {
        log(`${this.opts.name}: could not create ${dir}: ${err}`);
      }
    }
    const profile = claudeSandboxProfile(home, {
      folders: this.spawnedList ?? [],
      cliRoot: path.dirname(o.command),
      cwd,
      keychain: !o.env.ANTHROPIC_API_KEY,
      configDir,
    });
    return spawnClaudeSandboxed(o, profile, this.logStderr);
  };

  /// The sandbox policy (toolDecision) for this session's working directory.
  private get policy(): SandboxPolicy {
    // The folders that the running CLI's profile also allows: a folder added
    // while the session is busy is refused by the gate too, so the agent gets
    // a refusal that names what it can read, not an `EPERM` (code review
    // 2026-11-14). A removed folder is refused at once.
    const readable = (): readonly string[] => this.readableNow();
    return {
      home: this.opts.home ?? HOME,
      cwd: this.opts.cwd ?? agentCwd(this.opts.home ?? HOME),
      allowMcpActions: this.opts.allowMcpActions ?? false,
      // A getter: the gate keeps this object while the CLI runs, and the list
      // must be the one that the user has now (code review 2026-11-10).
      get readableFolders() {
        return readable();
      },
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
    if (SEATBELT) {
      this.spawnedList = this.opts.readableFolders?.() ?? [];
      const roots = readableRoots(this.policy.home, this.spawnedList);
      this.spawnedRoots = new Set(roots);
      this.spawnedFolders = JSON.stringify(roots);
    }
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
        ...(SEATBELT ? { spawnClaudeCodeProcess: this.spawnSandboxed } : {}),
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
        // The sandboxed spawn passes the same handler itself.
        stderr: this.logStderr,
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
