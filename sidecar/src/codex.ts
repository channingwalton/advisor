import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { Codex, type CodexOptions, type Thread, type ThreadOptions } from "@openai/codex-sdk";
import type { Agent, AgentSessionOptions, RunProgress, TaskResult } from "./agent.js";
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
///
/// Connectors and `noTools` are handled by `codexClientOptions`; here an empty
/// `allowedTools` turns web search and network off.
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

/// Codex client options for a session: auth, the CLI to spawn (`codexPath`, the
/// sandbox wrapper), and `--config` overrides.
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
/// everything is allowed, as on Claude.
///
/// `noTools` (the classifier) also switches off the shell, goals, image
/// generation, sleep and sub-agents. What no setting removes stays offered, and
/// which of it depends on the model (for example `request_user_input`,
/// `view_image`, `apply_patch`, the MCP resource tools, and code mode's `exec`);
/// each is inert here — see codex.sdk.test.ts.
export async function codexClientOptions(
  opts: AgentSessionOptions,
  env: NodeJS.ProcessEnv,
  codexPath: string,
  listServers: (codexPath: string, cwd: string) => Promise<string[]> = codexConfigServers
): Promise<CodexOptions> {
  const client = codexConstructorOptions(env, codexPath);
  if (opts.allowMcpActions === true && !opts.noTools) return client;
  const features: Record<string, boolean> = { apps: false, plugins: false };
  const config: NonNullable<CodexOptions["config"]> = { features };
  if (opts.noTools) {
    Object.assign(features, {
      shell_tool: false, unified_exec: false, goals: false, image_generation: false, sleep_tool: false,
      multi_agent: false, multi_agent_v2: false,
    });
    // A model's catalogue entry can turn sub-agents on (`multi_agent_version`),
    // whatever the features say. Only `[agents] enabled = false` overrides it.
    config.agents = { enabled: false };
  }
  const servers = await listServers(codexPath, opts.cwd ?? homedir());
  // The SDK writes each override as a dotted path, so a name with any other
  // character would disable some other key and leave this server running.
  const unsafe = servers.find((name) => !/^[A-Za-z0-9_-]+$/.test(name));
  if (unsafe !== undefined) throw new Error(`can't disable the Codex MCP server "${unsafe}": rename it`);
  if (servers.length > 0) {
    config.mcp_servers = Object.fromEntries(servers.map((name) => [name, { enabled: false }]));
  }
  return { ...client, config };
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
  resolve: (result: TaskResult) => void;
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
      new Codex(await codexClientOptions(opts, process.env, codexSandboxWrapper()))
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
    if (!this.client) {
      const client = this.createClient();
      this.client = client;
      client.catch(() => {
        if (this.client === client) this.client = undefined;
      });
    }
    return (await this.client).startThread(codexThreadOptions(this.opts));
  }

  run(task: string, progress?: RunProgress, timeoutMs = 180_000): Promise<TaskResult> {
    return new Promise((resolve) => {
      this.pending.push({ task, progress, timeoutMs, resolve });
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
        const input = this.firstTurn ? `${this.opts.systemPrompt}\n\n${task.task}` : task.task;
        this.firstTurn = false;
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
