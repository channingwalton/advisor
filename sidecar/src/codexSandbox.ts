import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { deniedPaths } from "./agent.js";

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

/// The two path lists as the kernel will match them: resolved, then deduped.
///
/// Resolving is not cosmetic. Seatbelt matches the real path, so a rule naming
/// a symlink matches nothing — and it fails in both directions. A dotfiles
/// setup that symlinks `~/.codex` to `~/dotfiles/.codex` silently loses its
/// write allowance (Codex cannot log in); one that symlinks `~/.ssh` silently
/// loses its read denial (the keys are readable). Found the first way round on
/// a real machine; the second is the one that matters.
export function sandboxPolicy(
  home: string,
  tmps: string[] = DEFAULT_TMPS
): { readDenials: string[]; writableRoots: string[] } {
  const resolve = (ps: string[]): string[] => [...new Set(ps.map(realpathOrSelf))];
  return {
    readDenials: resolve(sandboxReadDenials(home)),
    writableRoots: resolve(sandboxWritableRoots(home, tmps)),
  };
}

/// The sidecar's own `TMPDIR` plus the two macOS temp roots, because the CLI and
/// the MCP servers it spawns need not share this process's `TMPDIR`.
const DEFAULT_TMPS = [os.tmpdir(), "/private/tmp", "/private/var/folders"];

/// A macOS Seatbelt profile: everything allowed except reads of `readDenials`
/// and writes outside `writableRoots`.
/// Seatbelt takes the LAST matching rule, so the write allowances must follow
/// the blanket write denial. Paths are matched against the resolved path, so a
/// symlink out of an allowed directory cannot reach a denied one — the kernel
/// does here what `realResolve` does for the Claude backend.
export function seatbeltProfile(readDenials: string[], writableRoots: string[]): string {
  const subpaths = (ps: string[]): string =>
    ps.map((p) => `(subpath "${escapeSexp(p)}")`).join(" ");
  const lines = ["(version 1)", "(allow default)"];
  if (readDenials.length > 0) lines.push(`(deny file-read* ${subpaths(readDenials)})`);
  lines.push("(deny file-write*)");
  if (writableRoots.length > 0) lines.push(`(allow file-write* ${subpaths(writableRoots)})`);
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

/// Write the profile and wrapper into `dir` and return the wrapper's path,
/// suitable for `CodexOptions.codexPathOverride`.
export function installCodexSandbox(
  dir: string,
  home: string,
  realCodex: string,
  tmps: string[] = DEFAULT_TMPS
): string {
  const profilePath = path.join(dir, "advisor.sb");
  const wrapperPath = path.join(dir, "codex-sandboxed");
  const policy = sandboxPolicy(home, tmps);
  fs.writeFileSync(profilePath, seatbeltProfile(policy.readDenials, policy.writableRoots));
  fs.writeFileSync(wrapperPath, codexWrapperScript(realCodex, profilePath), { mode: 0o755 });
  fs.chmodSync(wrapperPath, 0o755); // mode above is subject to umask
  return wrapperPath;
}

/// Locate the Codex binary the SDK would otherwise spawn: the platform package
/// vendored under `@openai/codex`. Mirrors the SDK's own resolution, which is
/// not exported.
export function vendoredCodexPath(resolve = createRequire(import.meta.url).resolve): string {
  const triple = process.arch === "arm64" ? "aarch64-apple-darwin" : "x86_64-apple-darwin";
  const pkg = process.arch === "arm64" ? "@openai/codex-darwin-arm64" : "@openai/codex-darwin-x64";
  const root = path.dirname(resolve(`${pkg}/package.json`));
  for (const candidate of [
    path.join(root, "vendor", triple, "bin", "codex"),
    path.join(root, "vendor", triple, "codex", "codex"),
  ]) {
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error(`Codex CLI binary not found under ${root}`);
}

/// The wrapper the Codex backend must be spawned through, installed once per
/// sidecar process. Throws rather than returning undefined: an unsandboxed
/// Codex is the defect this closes, so failing to install the sandbox must
/// fail the backend, not silently widen it.
let cachedWrapper: string | undefined;
export function codexSandboxWrapper(home: string = os.homedir()): string {
  if (cachedWrapper) return cachedWrapper;
  if (process.platform !== "darwin") {
    throw new Error("the Codex backend requires macOS: its sandbox is Seatbelt-based");
  }
  const dir = path.join(home, "Library", "Application Support", "Advisor", "sandbox");
  fs.mkdirSync(dir, { recursive: true });
  cachedWrapper = installCodexSandbox(dir, realpathOrSelf(home), vendoredCodexPath());
  return cachedWrapper;
}
