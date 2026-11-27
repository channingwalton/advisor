import { execFile } from "node:child_process";
import fs from "node:fs";
import { homedir } from "node:os";
import { Codex, type CodexOptions, type Thread, type ThreadOptions } from "@openai/codex-sdk";
import { agentCwd, type Agent, type AgentSessionOptions, type RunProgress, type TaskResult } from "./agent.js";
import { codexFilesServer, codexSandboxWrapper, refreshCodexSandbox } from "./codexSandbox.js";
import { log } from "./protocol.js";
import { honouredFolders, readableFoldersNote, REALPATH } from "./toolPolicy.js";

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

/// The CLI's working folder: the agent working folder, as for Claude. The
/// Seatbelt profile refuses reads in the rest of the home folder
/// (GHSA-6xc8-f55f-jxqr), and the CLI reads instructions such as `AGENTS.md`
/// from its working folder.
export function codexWorkingDirectory(opts: AgentSessionOptions): string {
  return opts.cwd ?? agentCwd(opts.home ?? homedir());
}

/// Map an Advisor agent spec onto Codex thread options.
///
/// Sandbox: "read-only" + "never" approval is the CLI's own bound. It restricts
/// modification, not reading (see DESIGN.md), and MCP tools bypass it entirely
/// (openai/codex#4152), so Advisor does not rely on it for the paths that it
/// denies. The enforced boundary is the Seatbelt profile the CLI runs under — see
/// codexSandbox.ts — which denies the same paths as the Claude backend's
/// `canUseTool` and confines writes, for the CLI and every process it spawns.
///
/// The shell is off for each session (`codexClientOptions`, #119). Under the
/// profile, "read-only" also keeps it closed if a release offers it again: the
/// CLI applies its own Seatbelt profile to each command, macOS refuses it, and
/// no command runs (#118). "danger-full-access" makes the shell work, but the
/// profile then cannot stop a command that sends the `~/.codex` login out or
/// starts the CLI with every connector on. See DESIGN.md, *Codex shell stays
/// closed*.
///
/// The shell, connectors and `noTools` are handled by `codexClientOptions`;
/// here an empty `allowedTools` turns web search and network off.
export function codexThreadOptions(opts: AgentSessionOptions): ThreadOptions {
  const web = opts.allowedTools.some((t) => t.startsWith("Web"));
  return {
    model: opts.model,
    sandboxMode: "read-only",
    approvalPolicy: "never",
    skipGitRepoCheck: true,
    workingDirectory: codexWorkingDirectory(opts),
    webSearchEnabled: web,
    networkAccessEnabled: web,
  };
}

/// The name of Advisor's own MCP server, which gives a Codex card lane its file
/// tools (#120).
export const FILES_SERVER = "advisor";

/// Codex client options for a session: auth, the CLI to spawn (`codexPath`, the
/// sandbox wrapper), and `--config` overrides.
///
/// File tools: a card lane (one that reads the readable folders) gets
/// Advisor's own Read, Grep and Glob (`files`, localFilesMcp.ts), with
/// connector actions on and off. They apply Claude's read policy to each call,
/// and run under the profile. A server of the user's with their name fails
/// the session: an override merges into that server's settings rather than
/// replace them.
///
/// Connectors: the Claude backend lets read/search connector tools through and
/// refuses actions unless `allowMcpActions` (`mcpPermission`). Codex has no
/// per-call hook to do that, so without `allowMcpActions` a session gets no
/// connectors at all: ChatGPT apps and plugins (and the MCP servers plugins
/// bring) are switched off, and each server the user's config defines is
/// disabled by name. Overrides merge into the user's config rather than replace
/// it, so `mcp_servers = {}` would leave every server in place, and
/// `codex exec --ignore-user-config` would drop the user's model with them —
/// Preferences offers no Codex model of its own. With `allowMcpActions`,
/// every connector is allowed, as on Claude.
///
/// Shell: off for each session (`shell_tool`, `unified_exec`; issue #119).
/// Under Advisor's profile the CLI cannot apply its own sandbox to a command,
/// so no command runs (#118), and a card lane reads files through Advisor's
/// own tools (#120). With the shell off, that boundary does not depend on the
/// fault of the nested profile.
///
/// `noTools` (the classifier) also switches off goals, image generation, sleep
/// and sub-agents. What no setting removes stays offered, and which of it
/// depends on the model (for example `request_user_input`, `view_image`,
/// `apply_patch`, the MCP resource tools, and code mode's `exec`); each is
/// inert here — see codex.sdk.test.ts.
export async function codexClientOptions(
  opts: AgentSessionOptions,
  env: NodeJS.ProcessEnv,
  codexPath: string,
  listServers: (codexPath: string, cwd: string) => Promise<string[]> = codexConfigServers,
  files?: { command: string; args: string[] }
): Promise<CodexOptions> {
  const client = codexConstructorOptions(env, codexPath);
  const actions = opts.allowMcpActions === true && !opts.noTools;
  const ownFiles = opts.readableFolders !== undefined && !opts.noTools ? files : undefined;
  const features: Record<string, boolean> = { shell_tool: false, unified_exec: false };
  const config: NonNullable<CodexOptions["config"]> = { features };
  if (!actions) Object.assign(features, { apps: false, plugins: false });
  if (opts.noTools) {
    Object.assign(features, {
      goals: false, image_generation: false, sleep_tool: false, multi_agent: false, multi_agent_v2: false,
    });
    // A model's catalogue entry can turn sub-agents on (`multi_agent_version`),
    // whatever the features say. Only `[agents] enabled = false` overrides it.
    config.agents = { enabled: false };
  }
  // No server to disable, and no name to check against the file tools.
  if (actions && !ownFiles) return { ...client, config };
  const servers = await listServers(codexPath, codexWorkingDirectory(opts));
  if (ownFiles && servers.includes(FILES_SERVER)) {
    throw new Error(`a Codex MCP server is named "${FILES_SERVER}", the name of Advisor's file tools: rename it`);
  }
  const mcpServers: NonNullable<CodexOptions["config"]> = {};
  if (!actions) {
    // The SDK writes each override as a dotted path, so a name with any other
    // character would disable some other key and leave this server running.
    const unsafe = servers.find((name) => !/^[A-Za-z0-9_-]+$/.test(name));
    if (unsafe !== undefined) throw new Error(`can't disable the Codex MCP server "${unsafe}": rename it`);
    for (const name of servers) mcpServers[name] = { enabled: false };
  }
  if (ownFiles) mcpServers[FILES_SERVER] = ownFiles;
  if (Object.keys(mcpServers).length > 0) config.mcp_servers = mcpServers;
  return { ...client, config };
}

/// The note that starts each task of a Codex card lane: the folders that it can
/// read, as Claude's note gives them (`readableFoldersNote`), and where its
/// file tools are. Codex defers connector tools, so a model reaches them only
/// through tool search, or code mode's tool list, by name. Each task carries
/// it, because a thread outlives a change to the list.
export function codexFilesNote(home: string, folders: readonly string[], sessions: string | null = null): string {
  const note = readableFoldersNote(home, folders, REALPATH, sessions);
  if (honouredFolders(home, folders, REALPATH).length === 0) return note;
  return `${note} Read, Grep and Glob are the tools of Advisor's MCP server \`${FILES_SERVER}\` ` +
    `(\`mcp__${FILES_SERVER}__Read\`, \`mcp__${FILES_SERVER}__Grep\`, \`mcp__${FILES_SERVER}__Glob\`): ` +
    "when they are not in your tool list, find them with tool search, and read every file through them.";
}

/// The MCP servers the user's Codex config defines, by name: ~/.codex/config.toml
/// and a project's, as seen from `cwd`. Plugins' servers are left out, because
/// `features.plugins=false` drops them and an override naming one would be a
/// server with no command, which the CLI rejects. Rejects if the CLI fails, so a
/// session that can't list its servers fails rather than runs with them.
export function codexConfigServers(
  codexPath: string,
  cwd: string,
  env: NodeJS.ProcessEnv = process.env
): Promise<string[]> {
  return new Promise((resolve, reject) => {
    execFile(codexPath, ["mcp", "list", "--json", "-c", "features.plugins=false"], { cwd, env, timeout: 30_000 },
      (err, stdout, stderr) => {
        if (err) {
          reject(new Error(`listing Codex MCP servers failed: ${stderr.trim() || err.message}`));
          return;
        }
        try {
          const names = (JSON.parse(stdout) as { name?: unknown }[]).map((server) => server.name);
          if (names.some((name) => typeof name !== "string")) throw new Error("a server has no name");
          resolve(names as string[]);
        } catch (parseErr) {
          reject(new Error(`listing Codex MCP servers failed: ${parseErr}`));
        }
      });
  });
}

interface PendingTask {
  task: string;
  progress?: RunProgress;
  timeoutMs: number;
  recap?: string;
  resolve: (result: TaskResult) => void;
}

/**
 * A long-lived Codex thread fed one task at a time. Mirrors AgentSession's
 * contract: run() resolves with the answer text (or "" on failure) and never
 * throws; the thread retains context across tasks until reset().
 *
 * Codex has no system-prompt parameter, so the configured system prompt is
 * prepended to the first turn; later turns inherit it from thread context.
 * A task's recap goes into the first turn too, after the system prompt (#116).
 */
export class CodexAgentSession implements Agent {
  /// The client every thread of this session starts from, set up once (listing
  /// the user's MCP servers takes a CLI run) and shared, so a task stopped
  /// during setup and the one after it wait on the same setup. Cleared by
  /// reset(), so a recycled lane lists the servers again, and on failure, so
  /// the next task retries.
  private client?: Promise<Codex>;
  private thread?: Thread;
  private firstTurn = true;
  private pending: PendingTask[] = [];
  private active?: { stop: (error?: string) => void };

  constructor(
    private readonly opts: AgentSessionOptions,
    private readonly threadFactory?: (options: ThreadOptions) => Thread,
    private readonly createClient: () => Promise<Codex> = async () =>
      // Spawn the CLI through Advisor's Seatbelt wrapper. Throws if the sandbox
      // cannot be installed, or the user's MCP servers can't be listed to
      // disable them — guardedRun turns that into a visible error card, which
      // is the right outcome: an unsandboxed Codex would read every secret in
      // $HOME and, via MCP tools that bypass its own `read-only` mode
      // (openai/codex#4152), write anywhere too.
      new Codex(await codexClientOptions(opts, process.env, codexSandboxWrapper(), codexConfigServers, codexFilesServer())),
    /// Run before each turn's CLI starts: writes the Seatbelt profile with the
    /// readable folders of that moment (`refreshCodexSandbox`).
    private readonly prepareTurn: () => void = refreshCodexSandbox
  ) {}

  reset(): void {
    // Detach queued tasks before stopping the active turn can drain the queue.
    const pending = this.pending.splice(0);
    this.thread = undefined;
    this.client = undefined;
    this.firstTurn = true;
    this.active?.stop("agent session reset");
    for (const task of pending) {
      task.resolve({ text: "", error: "agent session reset" });
    }
  }

  async interrupt(): Promise<void> {
    // A lane assigns its card before run(), so that card can still be queued
    // behind a warm-up. Explicit cancellation must discard that queued work,
    // whereas an internal warm-up timeout may advance it.
    // Queued work never reached the thread, and the stop drops the thread.
    const pending = this.pending.splice(0);
    this.active?.stop();
    for (const task of pending) task.resolve({ text: "", contextLost: true });
  }

  private async newThread(): Promise<Thread> {
    if (this.threadFactory) return this.threadFactory(codexThreadOptions(this.opts));
    // The CLI cannot start in a missing folder; agentCwd is made on first use.
    fs.mkdirSync(codexWorkingDirectory(this.opts), { recursive: true });
    if (!this.client) {
      const client = this.createClient();
      this.client = client;
      client.catch(() => {
        if (this.client === client) this.client = undefined;
      });
    }
    return (await this.client).startThread(codexThreadOptions(this.opts));
  }

  run(task: string, progress?: RunProgress, timeoutMs = 180_000, recap?: string): Promise<TaskResult> {
    return new Promise((resolve) => {
      this.pending.push({ task, progress, timeoutMs, recap, resolve });
      this.drain();
    });
  }

  private drain(): void {
    if (this.active) return;
    const task = this.pending.shift();
    if (!task) return;

    const controller = new AbortController();
    // Accumulate agent_message items by id: a turn can emit more than one, and
    // each item.updated carries that item's full text so far. Keying by id means
    // streaming updates overwrite their own item while distinct items concatenate
    // (the old `buffer = ev.item.text` dropped all but the last).
    const messages = new Map<string, string>();
    const joined = (): string => [...messages.values()].join("\n\n");
    let settled = false;
    let timeoutHandle: NodeJS.Timeout | undefined;
    const finish = (error?: string, contextLost = false): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutHandle);
      this.active = undefined;
      task.resolve({ text: joined(), error, ...(contextLost ? { contextLost } : {}) });
      this.drain();
    };
    const dropThread = (): void => {
      this.thread = undefined;
      this.firstTurn = true;
    };
    this.active = {
      stop: (error) => {
        controller.abort();
        // An aborted CLI may still yield events or persist its last input.
        // Never resume that thread while the abandoned stream is draining.
        // A stop with no error (a cancel) must say that the conversation went
        // with the thread, or the lane keeps its transcript cursor (#112).
        dropThread();
        finish(error, error === undefined);
      },
    };
    timeoutHandle = setTimeout(() => {
      log(`${this.opts.name}: codex task timed out`);
      this.active?.stop("timed out");
    }, task.timeoutMs);
    timeoutHandle.unref();

    void (async () => {
      try {
        // Do not select a thread or consume its first-turn prompt until this
        // task owns the session. The SDK only gets its ID at thread.started.
        const thread = this.thread ?? (await this.newThread());
        // Stopped while the client was set up: it was resolved then, and only a
        // live task may install the thread, or a stale one could replace the
        // thread a later task is on.
        if (settled) return;
        this.thread = thread;
        // A new thread has none of the conversation. A timeout or a failed
        // turn drops the thread, so the next task starts one.
        if (this.firstTurn && task.recap) log(`${this.opts.name}: new thread, recap ${task.recap.length} chars`);
        const files = this.opts.readableFolders
          ? `${codexFilesNote(this.opts.home ?? homedir(), this.opts.readableFolders(), this.opts.pastSessions?.() ?? null)}\n\n`
          : "";
        const input = this.firstTurn
          ? `${this.opts.systemPrompt}\n\n${files}${task.recap ?? ""}${task.task}`
          : `${files}${task.task}`;
        this.firstTurn = false;
        // A profile that cannot be written fails the turn: the CLI would
        // start with the readable folders of an earlier turn.
        this.prepareTurn();
        const { events } = await thread.runStreamed(input, { signal: controller.signal });
        for await (const ev of events) {
          if (settled) break;
          if (ev.type === "item.updated" || ev.type === "item.completed") {
            if (ev.item.type === "agent_message") {
              messages.set(ev.item.id, ev.item.text);
              task.progress?.onText?.(joined());
            }
          } else if (ev.type === "turn.failed") {
            throw new Error(ev.error.message);
          } else if (ev.type === "error") {
            throw new Error(ev.message);
          }
        }
        finish();
      } catch (err) {
        if (settled) return;
        const message = err instanceof Error ? err.message : String(err);
        log(`${this.opts.name}: codex turn failed: ${err}`);
        dropThread();
        // List the user's servers again for the next task: one removed since
        // the last listing leaves an override the CLI rejects on every turn.
        this.client = undefined;
        finish(message);
      }
    })();
  }
}
