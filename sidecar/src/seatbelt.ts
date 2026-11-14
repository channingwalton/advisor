import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { deniedPaths, readableRoots } from "./agent.js";

// The Seatbelt profile parts that the Codex profile (codexSandbox.ts) and the
// Claude profile (claudeSandbox.ts) share (GHSA-6xc8-f55f-jxqr).

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
export function nativeOrSelf(p: string): string {
  try {
    return fs.realpathSync.native(p);
  } catch {
    return p;
  }
}

/// `realpathOrSelf` for a path that may not exist: the deepest existing ancestor
/// resolved, the rest appended as written (not existing, it can hold no symlink).
export function realpathLeaf(p: string): string {
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

/// The rules of the profile, each path as the kernel matches it.
export interface SeatbeltPolicy {
  /// The home folder: reads in it are refused, except `readRoots`, and the
  /// metadata of `readMetadata`.
  home: string[];
  readRoots: string[];
  /// Regular expressions on the full path, allowed as `readRoots` are: files
  /// that have no fixed name, such as the keychain's lock files.
  readPatterns: string[];
  /// The folders on the way from the home folder to a read root. The CLI
  /// resolves its paths (`canonicalize`), which needs their metadata, not
  /// their contents.
  readMetadata: string[];
  /// Refused in any case: the credential stores, as for the Claude agents.
  readDenials: string[];
  /// Whether writes are confined to `writableRoots` and `writePatterns`, less
  /// `writeDenials`. Both profiles confine them: a process that can write a
  /// folder can move a store out of it, and read it where it lands (code
  /// review 2026-11-14).
  confineWrites: boolean;
  writableRoots: string[];
  /// Regular expressions on the full path, writable as `writableRoots` are:
  /// files that have no fixed name, such as a keychain's temp files.
  writePatterns: string[];
  writeDenials: string[];
}

/// The temp folders that a sandboxed CLI, and the programs that it starts,
/// may write: `TMPDIR`, `/tmp`, and the per-user folders under
/// `/private/var/folders`, where macOS frameworks keep their caches.
export const TEMP_ROOTS: readonly string[] = [os.tmpdir(), "/private/tmp", "/private/var/folders"];

/// The temp folders in `tmps` that a profile lets a process write: each one
/// apart from the home folder, and each one in it that the policy honours as
/// a listed folder (`readableRoots`). A `TMPDIR` at, in or above a store, such
/// as `~`, `~/Library` or `/Users`, is left out: a process could move the
/// store out of it to `/tmp`, which it can write and read (code review
/// 2026-11-14). Each is judged by where its symlinks lead, as the kernel
/// matches it.
export function writableTemps(home: string, tmps: readonly string[]): string[] {
  const homes = [...new Set([home, realpathOrSelf(home), nativeOrSelf(home)])];
  // `inside` is `folder` or in it. Letter case is ignored, as in `holdingHome`.
  const within = (inside: string, folder: string): boolean => {
    const base = folder.endsWith(path.sep) ? folder : folder + path.sep;
    return inside.toLowerCase() === folder.toLowerCase() || inside.toLowerCase().startsWith(base.toLowerCase());
  };
  return tmps.filter((t) => {
    const resolved = realpathLeaf(t);
    if (homes.some((h) => within(resolved, h))) return readableRoots(home, [resolved]).length > 0;
    return !homes.some((h) => within(h, resolved));
  });
}

/// The read rules for the home folder, shared by the Codex and the Claude
/// profiles: the home folder is refused, then `judged` is allowed, each path
/// only when the policy honours it as a listed folder (`readableRoots`, so a
/// path at or above a store, such as `~/Library`, is not opened), and `state`,
/// the CLI's own files, which can be stores by design. A denylist fails open
/// for each store that it does not name, so the rest of the home folder is
/// refused (GHSA-6xc8-f55f-jxqr). Each state path in its listed and its
/// resolved form: the CLI reads a symlink in the listed form itself, such as
/// `~/.codex` when it leads into `~/dotfiles`.
export function homeReadRules(
  home: string,
  judged: readonly string[],
  state: readonly string[]
): Pick<SeatbeltPolicy, "home" | "readRoots" | "readMetadata"> {
  // The native form too: `readableRoots` gives the stored spelling, which can
  // differ in letter case from `$HOME`, and `foldersOnTheWay` compares
  // spellings (code review 2026-11-11).
  const homes = [...new Set([home, realpathOrSelf(home), nativeOrSelf(home)])];
  const readRoots = [...new Set([...readableRoots(home, judged), ...state.flatMap((p) => [p, realpathLeaf(p)])])];
  return { home: homes, readRoots, readMetadata: foldersOnTheWay(homes, readRoots) };
}

/// The credential stores, resolved, less `state`: the read denials that come
/// last in the profile, so a store stays refused inside an allowed folder.
export function storeDenials(home: string, state: readonly string[]): string[] {
  const keep = new Set(state);
  return [...new Set(deniedPaths(home).filter((p) => !keep.has(p)).map(realpathLeaf))];
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

/// A macOS Seatbelt profile: everything allowed except reads in the home
/// folder outside `readRoots`, reads of `readDenials`, and, when
/// `confineWrites`, writes outside `writableRoots`, less the `writeDenials`
/// (files or folders) inside them.
/// Seatbelt takes the LAST matching rule, so each allowance must follow the
/// blanket denial that it narrows, and the denials inside an allowance must
/// follow it. Paths are matched against the resolved path, so a symlink out of
/// an allowed directory cannot reach a denied one — the kernel does here what
/// `realResolve` does for the Claude backend. Every rule list is required: a
/// caller that forgot one would ship a profile without it.
export function seatbeltProfile(policy: SeatbeltPolicy): string {
  const { home, readRoots, readPatterns, readMetadata, readDenials, confineWrites, writableRoots, writePatterns, writeDenials } = policy;
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
  if (readPatterns.length > 0) {
    lines.push(`(allow file-read* ${readPatterns.map((r) => `(regex "${escapeSexp(r)}")`).join(" ")})`);
  }
  if (readMetadata.length > 0) lines.push(`(allow file-read-metadata ${literals(readMetadata)})`);
  // Last of the read rules: a store stays refused inside an allowed folder.
  if (readDenials.length > 0) lines.push(`(deny file-read* ${subpaths(readDenials)})`);
  if (confineWrites) {
    lines.push("(deny file-write*)");
    if (writableRoots.length > 0) lines.push(`(allow file-write* ${subpaths(writableRoots)})`);
    if (writePatterns.length > 0) {
      lines.push(`(allow file-write* ${writePatterns.map((r) => `(regex "${escapeSexp(r)}")`).join(" ")})`);
    }
    if (writeDenials.length > 0) lines.push(`(deny file-write* ${subpaths(writeDenials)})`);
  }
  return lines.join("\n") + "\n";
}

/// Escape a path for a regular expression, so a `.` or a `(` in a folder name
/// matches only itself.
export function escapeRegex(p: string): string {
  return p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/// Escape a path for a Seatbelt string literal. A `"` in a filename would
/// otherwise close the literal early and the rest of the path would be parsed
/// as profile syntax — at best a load failure, at worst a rule that does not
/// mean what it reads as.
function escapeSexp(p: string): string {
  return p.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

