import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { agentCwd } from "./agent.js";
import { loadReadableFolders } from "./config.js";
import {
  homeReadRules, realpathLeaf, realpathOrSelf, seatbeltProfile, storeDenials, TEMP_ROOTS, writableTemps, type SeatbeltPolicy,
} from "./seatbelt.js";

export { realpathOrSelf, seatbeltProfile, type SeatbeltPolicy } from "./seatbelt.js";

/// Codex's own state stays reachable: the CLI reads `~/.codex/auth.json` to
/// authenticate and persists threads in `~/.codex/sessions`, so denying it at
/// the OS level would break login. The agent can therefore still read its own
/// provider credentials — the one residual this sandbox cannot close and the
/// Claude backend's in-process denylist can. Recorded in DESIGN.md.
const PROVIDER_STATE = [".codex", ".codex-global-state.json"];

/// The only paths the sandboxed process may write to: Codex's own state (thread
/// persistence, logs), the temp dir it and its MCP servers scratch in, and
/// /dev. Everything else — the user's documents, code, dotfiles — is read-only
/// to the process, whatever the CLI's own `sandboxMode` does or does not honour.
export function sandboxWritableRoots(home: string, tmps: string[] = DEFAULT_TMPS): string[] {
  return [path.join(home, ".codex"), ...writableTemps(home, tmps), "/dev"];
}

/// What in Codex's own folder the agent may not write, folder allowance
/// notwithstanding: the inputs that shape the CLI's next turn or session. The
/// CLI re-reads its config every turn, and Advisor disables the user's
/// connectors by name through `--config` overrides (see codex.ts) — a written
/// `[mcp_servers.x]` block in `config.toml` would have a connector back next
/// turn, and `managed_config.toml` is layered *above* those overrides, so it
/// could re-enable one by name. `requirements.toml` constrains the CLI;
/// `hooks.json` runs commands; `.env` is loaded into the CLI's environment
/// (`OPENAI_BASE_URL` would redirect the user's token and transcript);
/// `AGENTS.md`, `instructions.md`, `agents/`, `skills/`, `rules/`, `prompts/`
/// and `plugins/` are instructions and commands every later session loads.
/// Codex's own read-only mode is the only other thing in the way, and it is not
/// relied on for these writes. `auth.json` stays writable (the OAuth token
/// refresh rewrites it), as does the CLI's working state (sessions, sqlite
/// databases, memories, logs, locks, temp files) — the set the CLI writes is large and changes with
/// releases, so it is the inputs that are listed, not the outputs. Two of those
/// outputs are read back (a resumed thread's rollout, the memories): known
/// residuals, recorded in DESIGN.md. A denylist, so a new input class in a Codex
/// release is a gap until it is added here; the inverse (an allowlist of state)
/// would instead break the backend on an unexpected write. Code review 2026-10-17.
export function sandboxWriteDenials(home: string): string[] {
  return [
    "config.toml", "managed_config.toml", "requirements.toml", "hooks.json", ".env",
    "AGENTS.md", "instructions.md", "agents", "skills", "rules", "prompts", "plugins",
  ].map((f) => path.join(home, ".codex", f));
}

/// What the profile lets the sandboxed process read in the home folder
/// (GHSA-6xc8-f55f-jxqr).
export interface ReadAllowance {
  /// The folders that the user lists as readable, as config.json holds them.
  folders: readonly string[];
  /// The folder that holds the Codex CLI and the helper programs that it runs.
  cliRoot: string;
  /// The CLI's working folder.
  cwd: string;
}

/// The path lists as the kernel will match them: resolved, then deduped.
///
/// Resolving is not cosmetic. Seatbelt matches the real path, so a rule naming
/// a symlink matches nothing — and it fails in both directions. A dotfiles
/// setup that symlinks `~/.codex` to `~/dotfiles/.codex` silently loses its
/// write allowance (Codex cannot log in); one that symlinks `~/.ssh` silently
/// loses its read denial (the keys are readable). Found the first way round on
/// a real machine; the second is the one that matters. (Seatbelt matches the
/// file, not its spelling: a rule for `.codex` holds for `.Codex`, for another
/// Unicode normal form and for `.ſsh`, checked 2026-11-11. So the resolve need
/// not be the native one.)
export function sandboxPolicy(home: string, reads: ReadAllowance, tmps: string[] = DEFAULT_TMPS): SeatbeltPolicy {
  // `realpathLeaf`, not `realpathOrSelf`: a path that does not exist yet, such
  // as `~/.codex` on a first run, must still be named in its resolved form
  // when the home folder is reached through a symlink (code review 2026-11-11).
  const resolve = (ps: string[]): string[] => [...new Set(ps.map(realpathLeaf))];
  const writableRoots = resolve(sandboxWritableRoots(home, tmps));
  const state = PROVIDER_STATE.map((p) => path.join(home, p));
  return {
    // The writable roots too: what the process writes, it reads back. Each is
    // judged as a listed folder is, so a `TMPDIR` at or above a store, such as
    // `~/Library`, is not read (code review 2026-11-11), and `writableTemps`
    // leaves it out of the writable roots (code review 2026-11-14).
    ...homeReadRules(home, [...reads.folders, reads.cliRoot, reads.cwd, ...writableRoots], state),
    readDenials: storeDenials(home, state),
    readPatterns: [],
    confineWrites: true,
    writableRoots,
    writePatterns: [],
    writeDenials: [...new Set(sandboxWriteDenials(home).flatMap(inputDenialPaths))],
  };
}

/// The paths the kernel must match to keep an input unwritable. Its own name,
/// resolved as far as it exists (the folder is the part a dotfiles symlink
/// redirects) — the input may not exist yet, and when it is a symlink the name
/// is what `rm` and a fresh `>` act on. And, when it is a symlink, its target
/// (dangling or not), read relative to the *resolved* folder the link sits in:
/// that is where the kernel matches a write *through* the link. Either alone
/// was bypassable (code review 2026-10-17). A symlink nested inside a denied
/// folder is not followed — a known residual, recorded in DESIGN.md.
function inputDenialPaths(p: string): string[] {
  // The folder resolved, the name kept: `realpathLeaf(p)` would follow the link.
  const name = path.join(realpathLeaf(path.dirname(p)), path.basename(p));
  try {
    if (!fs.lstatSync(p).isSymbolicLink()) return [name];
    const target = path.resolve(path.dirname(name), fs.readlinkSync(p));
    return [name, realpathLeaf(target)];
  } catch {
    return [name]; // does not exist: the name is all there is
  }
}

/// The sidecar's own `TMPDIR` plus the two macOS temp roots, because the CLI and
/// the MCP servers it spawns need not share this process's `TMPDIR`.
const DEFAULT_TMPS = [...TEMP_ROOTS];

/// A shell wrapper that execs the real Codex CLI under `profilePath`. The SDK
/// spawns `codexPathOverride` directly (no shell) and pipes stdio, so a shebang
/// script that `exec`s through sandbox-exec is transparent to it.
export function codexWrapperScript(realCodex: string, profilePath: string): string {
  return `#!/bin/sh\nexec /usr/bin/sandbox-exec -f ${shellQuote(profilePath)} ${shellQuote(realCodex)} "$@"\n`;
}

function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

/// Write the profile into `dir` and return its path. The write is atomic (a
/// new file, then a rename), so a CLI that starts meanwhile reads the old
/// profile or the new one, never a part of one.
export function writeCodexProfile(
  dir: string,
  home: string,
  reads: ReadAllowance,
  tmps: string[] = DEFAULT_TMPS
): string {
  const profilePath = path.join(dir, "advisor.sb");
  const temp = `${profilePath}.${process.pid}.tmp`;
  fs.writeFileSync(temp, seatbeltProfile(sandboxPolicy(home, reads, tmps)));
  fs.renameSync(temp, profilePath);
  return profilePath;
}

/// Write the profile and wrapper into `dir` and return the wrapper's path,
/// suitable for `CodexOptions.codexPathOverride`.
export function installCodexSandbox(
  dir: string,
  home: string,
  realCodex: string,
  reads: ReadAllowance,
  tmps: string[] = DEFAULT_TMPS
): string {
  const wrapperPath = path.join(dir, "codex-sandboxed");
  const profilePath = writeCodexProfile(dir, home, reads, tmps);
  fs.writeFileSync(wrapperPath, codexWrapperScript(realCodex, profilePath), { mode: 0o755 });
  fs.chmodSync(wrapperPath, 0o755); // mode above is subject to umask
  return wrapperPath;
}

/// Locate the Codex binary the SDK would otherwise spawn: the platform package
/// vendored under `@openai/codex`. Mirrors the SDK's own resolution, which is
/// not exported.
export function vendoredCodexPath(resolve = createRequire(import.meta.url).resolve): string {
  const triple = process.arch === "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin";
  const root = vendoredCodexRoot(resolve);
  for (const candidate of [
    path.join(root, "vendor", triple, "bin", "codex"),
    path.join(root, "vendor", triple, "codex", "codex"),
  ]) {
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(`Codex CLI binary not found under ${root}`);
}

/// The platform package that holds the Codex CLI and the helper programs that
/// it runs (`codex-code-mode-host`, ripgrep). The profile lets the CLI read
/// it: in a dev checkout it is in the home folder.
export function vendoredCodexRoot(resolve = createRequire(import.meta.url).resolve): string {
  const pkg = process.arch === "arm64" ? "@openai/codex-darwin-arm64" : "@openai/codex-darwin-x64";
  return path.dirname(resolve(`${pkg}/package.json`));
}

/// The wrapper the Codex backend must be spawned through, installed once per
/// sidecar process. Throws rather than returning undefined: an unsandboxed
/// Codex is the defect this closes, so failing to install the sandbox must
/// fail the backend, not silently widen it.
let installed: { wrapper: string; dir: string; home: string; reads: () => ReadAllowance } | undefined;
export function codexSandboxWrapper(home: string = os.homedir()): string {
  if (installed) return installed.wrapper;
  if (process.platform !== "darwin") {
    throw new Error("the Codex backend requires macOS: its sandbox is Seatbelt-based");
  }
  const dir = path.join(home, "Library", "Application Support", "Advisor", "sandbox");
  fs.mkdirSync(dir, { recursive: true });
  const cliRoot = vendoredCodexRoot();
  const cwd = agentCwd(home);
  const reads = (): ReadAllowance => ({ folders: loadReadableFolders(), cliRoot, cwd });
  // The home as `$HOME` spells it, not resolved: a folder listed through a
  // symlinked home must be in it, as for Claude (`readableRoots` checks both
  // forms). `sandboxPolicy` resolves each path that it writes.
  installed = { wrapper: installCodexSandbox(dir, home, vendoredCodexPath(), reads()), dir, home, reads };
  return installed.wrapper;
}

/// Write the profile again with the readable folders that config.json lists
/// now. Each Codex turn starts a new CLI, which reads the profile as it
/// starts, so a turn reads the folders of that moment: a folder that the user
/// removes is refused from the next turn on. Nothing to do before the wrapper
/// is installed in this process. Node runs this to its end before any other
/// session's turn, so a write with an older list cannot follow a newer one.
export function refreshCodexSandbox(): void {
  if (installed) writeCodexProfile(installed.dir, installed.home, installed.reads());
}
