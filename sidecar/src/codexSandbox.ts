import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { agentCwd, deniedPaths, readableRoots } from "./agent.js";
import { loadReadableFolders } from "./config.js";

/// Codex's own state stays reachable: the CLI reads `~/.codex/auth.json` to
/// authenticate and persists threads in `~/.codex/sessions`, so denying it at
/// the OS level would break login. The agent can therefore still read its own
/// provider credentials — the one residual this sandbox cannot close and the
/// Claude backend's in-process denylist can. Recorded in DESIGN.md.
const PROVIDER_STATE = [".codex", ".codex-global-state.json"];

/// Resolve symlinks so the profile names the path the kernel will match
/// (`/tmp` is a symlink to `/private/tmp` on macOS, and a profile written
/// against the unresolved path matches nothing). Non-existent paths are kept
/// as-is: they can hold no symlink, and denying a path that may be created
/// later is the safe direction.
export function realpathOrSelf(p: string): string {
  try {
    return fs.realpathSync(p);
  } catch {
    return p;
  }
}

/// `p` with each name as the disk stores it, or `p` when it does not exist.
function nativeOrSelf(p: string): string {
  try {
    return fs.realpathSync.native(p);
  } catch {
    return p;
  }
}

/// Paths the OS-level sandbox must keep unreadable — the same list the Claude
/// backend's `canUseTool` enforces, minus Codex's own state (see above), so one
/// denylist drives both backends.
export function sandboxReadDenials(home: string): string[] {
  const keep = new Set(PROVIDER_STATE.map((p) => path.join(home, p)));
  return deniedPaths(home).filter((p) => !keep.has(p));
}

/// The only paths the sandboxed process may write to: Codex's own state (thread
/// persistence, logs), the temp dir it and its MCP servers scratch in, and
/// /dev. Everything else — the user's documents, code, dotfiles — is read-only
/// to the process, whatever the CLI's own `sandboxMode` does or does not honour.
export function sandboxWritableRoots(home: string, tmps: string[] = DEFAULT_TMPS): string[] {
  return [path.join(home, ".codex"), ...tmps, "/dev"];
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

/// The rules of the profile, each path as the kernel matches it.
export interface SeatbeltPolicy {
  /// The home folder: reads in it are refused, except `readRoots`, and the
  /// metadata of `readMetadata`.
  home: string[];
  readRoots: string[];
  /// The folders on the way from the home folder to a read root. The CLI
  /// resolves its paths (`canonicalize`), which needs their metadata, not
  /// their contents.
  readMetadata: string[];
  /// Refused in any case: the credential stores, as for the Claude agents.
  readDenials: string[];
  writableRoots: string[];
  writeDenials: string[];
}

/// The paths of the home folder that the sandboxed process can read: the
/// readable folders, the CLI and working folders and `writable` (the writable
/// roots: what the process writes, it reads back), each only when the policy
/// honours it as a listed folder (`readableRoots`). So a `TMPDIR` or a CLI
/// folder at or above a store, such as `~/Library`, is not opened (code review
/// 2026-11-11). And Codex's own state, which is a store by design. A denylist
/// fails open for each store that it does not name, so the rest of the home
/// folder is refused (GHSA-6xc8-f55f-jxqr). Each path in its listed and its
/// resolved form: the CLI reads a symlink in the listed form itself, such as
/// `~/.codex` when it leads into `~/dotfiles`.
function sandboxReadRoots(home: string, reads: ReadAllowance, writable: string[]): string[] {
  const state = PROVIDER_STATE.map((p) => path.join(home, p));
  return [...new Set([
    ...readableRoots(home, [...reads.folders, reads.cliRoot, reads.cwd, ...writable]),
    ...state.flatMap((p) => [p, realpathLeaf(p)]),
  ])];
}

/// The home folder in `homes` that holds `p`. Letter case is ignored, as the
/// default volume and Seatbelt ignore it: a path can come in a spelling other
/// than `$HOME`'s (code review 2026-11-11). On a case-sensitive volume this
/// can only add a rule for a path outside the home folder, which the profile
/// does not refuse anyway.
function holdingHome(homes: string[], p: string): string | undefined {
  return homes.find((h) => p.toLowerCase().startsWith((h + path.sep).toLowerCase()));
}

/// Each folder between a home folder in `homes` and a path in `roots`, that
/// home folder included.
function foldersOnTheWay(homes: string[], roots: string[]): string[] {
  const folders = new Set<string>();
  for (const root of roots) {
    const home = holdingHome(homes, root);
    if (home === undefined) continue;
    for (let dir = path.dirname(root); ; dir = path.dirname(dir)) {
      folders.add(dir);
      // The root guard: a spelling that never reaches `home` stops at `/`.
      if (dir.toLowerCase() === home.toLowerCase() || dir === path.dirname(dir)) break;
    }
  }
  return [...folders];
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
  // The native form too: `readableRoots` gives the stored spelling, which can
  // differ in letter case from `$HOME`, and `foldersOnTheWay` compares
  // spellings (code review 2026-11-11).
  const homes = [...new Set([home, realpathOrSelf(home), nativeOrSelf(home)])];
  const writableRoots = resolve(sandboxWritableRoots(home, tmps));
  // `readableRoots` keeps only the writable roots inside the home folder: the
  // rest are readable anyway, and a root that holds the home folder would open
  // all of it.
  const readRoots = sandboxReadRoots(home, reads, writableRoots);
  return {
    home: homes,
    readRoots,
    readMetadata: foldersOnTheWay(homes, readRoots),
    readDenials: resolve(sandboxReadDenials(home)),
    writableRoots,
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

/// `realpathOrSelf` for a path that may not exist: the deepest existing ancestor
/// resolved, the rest appended as written (not existing, it can hold no symlink).
function realpathLeaf(p: string): string {
  const tail: string[] = [];
  let cur = p;
  for (;;) {
    try {
      return path.join(fs.realpathSync(cur), ...tail.reverse());
    } catch {
      const parent = path.dirname(cur);
      if (parent === cur) return p;
      tail.push(path.basename(cur));
      cur = parent;
    }
  }
}

/// Programs that start another program outside the profile, through launchd or
/// Apple Events: refused outright. The exec denial is by path, but a copy of
/// one of these system binaries will not run either — macOS launch constraints
/// pin them to their canonical location and kill a copy with a Launch
/// Constraint Violation (verified on macOS 27, sandboxed and not). What the
/// exec denial cannot reach is the library route: a process can call
/// LaunchServices directly (`LSOpenCFURLRef` over mach/XPC) and hand a program
/// to launchd without running any launcher binary. `LAUNCH_SERVICES_REGEX`
/// closes that route at the mach port.
const LAUNCHERS = ["/usr/bin/osascript", "/usr/bin/open", "/bin/launchctl", "/usr/bin/shortcuts"];

/// The `com.apple.lsd` mach services — the LaunchServices daemon — matched as a
/// family: the bare `com.apple.lsd` and every `com.apple.lsd.*` sub-service. The
/// family is what resolves a URL or bundle id to the app to launch; deny the
/// whole lookup and LaunchServices is unreachable, so neither `open` nor a
/// direct `LSOpenCFURLRef` call can resolve a handler, let alone launch it. A
/// regex rather than a name list because resolution has fallbacks: an explicit
/// `com.apple.lsd`/`launchservicesd` denial still resolves through the
/// sub-services (verified against the kernel). Nothing the CLI or an MCP server
/// does needs to launch an app — the real CLI completes its turns regardless
/// (`codex.sdk.test.ts`). Code review #88.
const LAUNCH_SERVICES_REGEX = "^com\\.apple\\.lsd";

/// The sidecar's own `TMPDIR` plus the two macOS temp roots, because the CLI and
/// the MCP servers it spawns need not share this process's `TMPDIR`.
const DEFAULT_TMPS = [os.tmpdir(), "/private/tmp", "/private/var/folders"];

/// A macOS Seatbelt profile: everything allowed except reads in the home
/// folder outside `readRoots`, reads of `readDenials`, and writes outside
/// `writableRoots`, less the `writeDenials` (files or folders) inside them.
/// Seatbelt takes the LAST matching rule, so each allowance must follow the
/// blanket denial that it narrows, and the denials inside an allowance must
/// follow it. Paths are matched against the resolved path, so a symlink out of
/// an allowed directory cannot reach a denied one — the kernel does here what
/// `realResolve` does for the Claude backend. Every rule list is required: a
/// caller that forgot one would ship a profile without it.
export function seatbeltProfile(policy: SeatbeltPolicy): string {
  const { home, readRoots, readMetadata, readDenials, writableRoots, writeDenials } = policy;
  const subpaths = (ps: string[]): string =>
    ps.map((p) => `(subpath "${escapeSexp(p)}")`).join(" ");
  const literals = (ps: string[]): string =>
    ps.map((p) => `(literal "${escapeSexp(p)}")`).join(" ");
  const lines = [
    "(version 1)",
    "(allow default)",
    // `osascript -e 'tell app "Finder" to do shell script "cat ~/.ssh/id_rsa"'`
    // would run the script inside Finder, outside this profile (gated only by
    // a TCC prompt), and `open`/`launchctl`/`shortcuts` hand a program to
    // launchd the same way. Nothing the CLI or an MCP server does needs Apple
    // Events or those launchers.
    "(deny appleevent-send)",
    `(deny process-exec ${LAUNCHERS.map((p) => `(literal "${p}")`).join(" ")})`,
    `(deny mach-lookup (global-name-regex "${LAUNCH_SERVICES_REGEX}"))`,
  ];
  if (home.length > 0) lines.push(`(deny file-read* ${subpaths(home)})`);
  if (readRoots.length > 0) lines.push(`(allow file-read* ${subpaths(readRoots)})`);
  if (readMetadata.length > 0) lines.push(`(allow file-read-metadata ${literals(readMetadata)})`);
  // Last of the read rules: a store stays refused inside an allowed folder.
  if (readDenials.length > 0) lines.push(`(deny file-read* ${subpaths(readDenials)})`);
  lines.push("(deny file-write*)");
  if (writableRoots.length > 0) lines.push(`(allow file-write* ${subpaths(writableRoots)})`);
  if (writeDenials.length > 0) lines.push(`(deny file-write* ${subpaths(writeDenials)})`);
  return lines.join("\n") + "\n";
}

/// Escape a path for a Seatbelt string literal. A `"` in a filename would
/// otherwise close the literal early and the rest of the path would be parsed
/// as profile syntax — at best a load failure, at worst a rule that does not
/// mean what it reads as.
function escapeSexp(p: string): string {
  return p.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

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
