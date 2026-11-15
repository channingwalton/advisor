import fs from "node:fs";
import path from "node:path";
import { absolutePath, braceAlternatives, toolDecision, type SandboxPolicy } from "./toolPolicy.js";

/// Advisor's own file tools for Codex card lanes (#120): Read, Grep and Glob,
/// read-only, with the names and inputs of Claude's tools. Codex has no
/// per-call hook, and its own shell cannot run under Advisor's profile (#118),
/// so a Codex card reads local files only through these tools. Each call goes
/// through Claude's policy (`toolDecision`) before it opens a file, so a Codex
/// card reads what a Claude card reads. The connector process also runs under
/// the Codex Seatbelt profile (codexSandbox.ts), which refuses the rest of the
/// home folder. This module loads only Node's own modules and the policy, so
/// the profile need not let the connector read the agent SDKs.

export interface FileToolResult {
  text: string;
  isError?: true;
}

/// The most lines that Read returns when the call gives no `limit`.
const READ_LINES = 2000;
/// A longer line is cut: one minified line can fill the model's context.
const LINE_CHARS = 2000;
/// The largest file that Read and Grep open.
const FILE_BYTES = 10 * 1024 * 1024;
/// The most paths that Glob, or lines that Grep, returns.
const RESULTS = 250;
/// A file with a NUL byte in its first part is binary.
const BINARY_PROBE = 8000;

const readOnly = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false };

/// The tools as `tools/list` offers them. The descriptions are what the model
/// reads to choose a tool and its inputs.
export const FILE_TOOLS = [
  {
    name: "Read",
    description:
      "Read a local text file inside the folders that Advisor lets you read. `file_path` is an absolute path. " +
      "Returns the file's lines, numbered. For a long file, `offset` is the first line to read (from 1) and " +
      "`limit` is the number of lines.",
    inputSchema: {
      type: "object",
      properties: {
        file_path: { type: "string", description: "The absolute path of the file." },
        offset: { type: "integer", minimum: 1, description: "The first line to read, from 1." },
        limit: { type: "integer", minimum: 1, description: "The number of lines to read." },
      },
      required: ["file_path"],
    },
    annotations: readOnly,
  },
  {
    name: "Grep",
    description:
      "Search the contents of local files inside a folder that Advisor lets you read. `pattern` is a JavaScript " +
      "regular expression. `path` is an absolute folder or file. `glob` limits the files, such as `*.md`. " +
      "`output_mode` is `files_with_matches` (the default: paths, newest first), `content` (path:line:text) or " +
      "`count`. Hidden files and symlinks are skipped.",
    inputSchema: {
      type: "object",
      properties: {
        pattern: { type: "string", description: "The regular expression to search for." },
        path: { type: "string", description: "The absolute folder or file to search." },
        glob: { type: "string", description: "Search only the files that match this glob, such as `*.md`." },
        output_mode: { type: "string", enum: ["files_with_matches", "content", "count"] },
        "-i": { type: "boolean", description: "Ignore case." },
      },
      required: ["pattern", "path"],
    },
    annotations: readOnly,
  },
  {
    name: "Glob",
    description:
      "Find local files by name inside a folder that Advisor lets you read. `path` is the absolute folder; " +
      "`pattern` is relative to it, such as `**/*.md`. Returns paths, newest first. Symlinks are skipped (Read " +
      "follows one), and hidden files are listed only when the pattern names them, such as `.obsidian/*`.",
    inputSchema: {
      type: "object",
      properties: {
        pattern: { type: "string", description: "The glob, relative to `path`, such as `**/*.md`." },
        path: { type: "string", description: "The absolute folder to search." },
      },
      required: ["pattern", "path"],
    },
    annotations: readOnly,
  },
];

const failure = (text: string): FileToolResult => ({ text, isError: true });

/// The error code of a failed file call, such as `EPERM`, or its message.
const reason = (e: unknown): string => (e as NodeJS.ErrnoException).code ?? String(e);

/// Run one tool call. The policy judges the call first; a refusal is an error
/// whose text names the folders that the agent can read.
export function fileTool(name: string, input: unknown, policy: SandboxPolicy): FileToolResult {
  if (!FILE_TOOLS.some((t) => t.name === name)) return failure(`${name} is not one of Advisor's file tools.`);
  const decision = toolDecision(name, input, policy);
  if (decision.behavior === "deny") return failure(decision.message);
  const args = input as Record<string, unknown>;
  switch (name) {
    case "Read":
      return read(absolutePath(args.file_path, policy.home)!, args, policy);
    case "Glob":
      return glob(absolutePath(args.path, policy.home)!, args, policy);
    default:
      return grep(absolutePath(args.path, policy.home)!, args, policy);
  }
}

const positive = (n: unknown): boolean => Number.isInteger(n) && (n as number) >= 1;

/// How Read and Grep open a file: read-only, refusing a symlink at the end of
/// the path, and not waiting for a writer when the file is a pipe.
const OPEN_FLAGS = fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK;

/// The text of a regular file that Read or Grep may show, and its change
/// time, or why not. `file` is a resolved path, so it holds no symlink: one
/// swapped in at its end since then is refused (`O_NOFOLLOW`), and the file is
/// judged by what the open gave (`fstat`). `shown` is the path that an error
/// names.
function textOf(file: string, shown: string = file): { text: string; mtime: number } | { error: string } {
  let fd: number;
  try {
    fd = fs.openSync(file, OPEN_FLAGS);
  } catch (e) {
    if (reason(e) === "ELOOP") return { error: `${shown} changed to a symlink.` };
    return { error: `Could not open ${shown}: ${reason(e)}.` };
  }
  try {
    const stat = fs.fstatSync(fd);
    if (stat.isDirectory()) return { error: `${shown} is a folder: find its files with Glob.` };
    if (!stat.isFile()) return { error: `${shown} is not a regular file.` };
    if (stat.size > FILE_BYTES) return { error: `${shown} is larger than ${FILE_BYTES / 1024 / 1024} MB.` };
    const data = fs.readFileSync(fd);
    if (data.subarray(0, BINARY_PROBE).includes(0)) return { error: `${shown} is a binary file.` };
    return { text: data.toString("utf8"), mtime: stat.mtimeMs };
  } catch (e) {
    return { error: `Could not read ${shown}: ${reason(e)}.` };
  } finally {
    fs.closeSync(fd);
  }
}

/// `given` as it resolves now, judged again as `tool` with `args`: a symlink
/// that changed after the policy judged the call is judged where it leads now.
/// The tools then work from this path, which holds no symlink and no `..`, so
/// what they open is what was judged, and a `..` after a symlink cannot make
/// a lexical join name another file (code review 2026-11-14).
function resolvedNow(
  tool: string,
  given: string,
  args: Record<string, unknown>,
  policy: SandboxPolicy
): { real: string } | { failure: FileToolResult } {
  let real: string;
  try {
    real = fs.realpathSync.native(given);
  } catch (e) {
    return { failure: failure(`Could not open ${given}: ${reason(e)}.`) };
  }
  if (real === given) return { real };
  const key = tool === "Read" ? "file_path" : "path";
  const decision = toolDecision(tool, { ...args, [key]: real }, policy);
  return decision.behavior === "deny" ? { failure: failure(decision.message) } : { real };
}

/// The lines of a text, without the empty line after a final newline.
function linesOf(text: string): string[] {
  const lines = text.split(/\r?\n/);
  if (lines.at(-1) === "") lines.pop();
  return lines;
}

const cut = (line: string): string => (line.length > LINE_CHARS ? `${line.slice(0, LINE_CHARS)}…` : line);

function read(file: string, args: Record<string, unknown>, policy: SandboxPolicy): FileToolResult {
  const { offset, limit } = args;
  if (offset !== undefined && !positive(offset)) return failure("`offset` must be a whole number from 1.");
  if (limit !== undefined && !positive(limit)) return failure("`limit` must be a whole number from 1.");
  const now = resolvedNow("Read", file, args, policy);
  if ("failure" in now) return now.failure;
  const content = textOf(now.real, file);
  if ("error" in content) return failure(content.error);
  const lines = linesOf(content.text);
  if (lines.length === 0) return { text: "(The file is empty.)" };
  const start = ((offset as number | undefined) ?? 1) - 1;
  if (start >= lines.length) return { text: `(The file has ${lines.length} lines.)` };
  const shown = lines.slice(start, start + ((limit as number | undefined) ?? READ_LINES));
  const body = shown.map((line, i) => `${String(start + i + 1).padStart(6)}\t${cut(line)}`).join("\n");
  const end = start + shown.length;
  if (end >= lines.length) return { text: body };
  return { text: `${body}\n\n(Showing lines ${start + 1}–${end} of ${lines.length}: read on with offset ${end + 1}.)` };
}

/// Paths newest first, at most `RESULTS` of them, or `none`.
function newestFirst(files: { file: string; mtime: number }[], none: string): string {
  if (files.length === 0) return none;
  const sorted = files.sort((a, b) => b.mtime - a.mtime || a.file.localeCompare(b.file)).map((f) => f.file);
  return listed(sorted);
}

/// At most `RESULTS` lines, and how many more there are.
function listed(lines: string[]): string {
  if (lines.length <= RESULTS) return lines.join("\n");
  const more = lines.length - RESULTS;
  return `${lines.slice(0, RESULTS).join("\n")}\n\n(${more} more not shown: narrow the pattern or the path.)`;
}

/// Glob, from the resolved root (`globFiles`).
function glob(root: string, args: Record<string, unknown>, policy: SandboxPolicy): FileToolResult {
  const { pattern } = args;
  if (typeof pattern !== "string" || pattern === "") return failure("Glob needs a `pattern`, such as `**/*.md`.");
  const now = resolvedNow("Glob", root, args, policy);
  if ("failure" in now) return now.failure;
  try {
    if (!fs.statSync(now.real).isDirectory()) return failure(`${root} is not a folder: Read it, or give its folder as \`path\`.`);
  } catch (e) {
    return failure(`Glob could not search ${root}: ${reason(e)}.`);
  }
  return { text: newestFirst(globFiles(now.real, pattern), "No files found") };
}

/// The regular files under `root` whose path from `root` matches `pattern`
/// (`globMatcher`), with their modification times. It walks `root` itself
/// and follows no symlink that it finds, so a pattern cannot take it out of
/// the folder that the policy judged, and the folder can hold no store
/// (`readableRoots`). A folder that another process swaps for a symlink
/// during the walk gives nothing (`walk`). `fs.globSync`, which Glob ran
/// before, reads `[.][.]`, `{x,\}/etc` and `.{},.}` in ways that leave the
/// folder (2026-11-14). As `fs.globSync` did, it enters a hidden folder only
/// for a pattern that can match a hidden name, and goes no deeper than the
/// pattern can match (`reach`). It starts at the folder that the pattern's
/// leading names give (`walkStart`). `fold`, on macOS by default, matches
/// names as macOS volumes find them (`CASE_FOLDS`). `root` is a resolved
/// path, as `walk` needs.
export function globFiles(root: string, pattern: string, fold = CASE_FOLDS): Found[] {
  const normalised = normalisedGlob(pattern);
  const matches = globMatcher(normalised, fold);
  const { hidden, depth } = reach(normalised);
  const start = walkStart(root, normalised, fold);
  if (start === undefined) return [];
  const below = start === root ? 0 : path.relative(root, start).split(path.sep).length;
  const keep = (file: string): Found | undefined => (matches(path.relative(root, file)) ? statOf(file) : undefined);
  return walk(start, hidden, keep, depth - below);
}

type Found = { file: string; mtime: number };

/// The file and its modification time, when it is a regular file.
function statOf(file: string): Found | undefined {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() ? { file, mtime: stat.mtimeMs } : undefined;
  } catch {
    return undefined;
  }
}

/// Where a normalised glob can match, judged on the safe side for each of its
/// brace alternatives (`braceAlternatives`, so `{x,}.git` is `.git`), each
/// without its `.`, `[.]` and empty names (`{./a,x}.md` is one name deep):
/// whether
/// it can match a hidden name, and how many names deep. `path.matchesGlob`
/// matches a hidden name only for a name in the pattern that starts with a
/// dot, with `[.]`, or with an extglob that holds a dot (`@(x|.git)`) or can be
/// empty before one (`?(x).git`); not with `[0-9]` or `[!x]` (2026-11-15). The
/// safe side costs only folder reads: a name that starts with a dot, a class
/// with a dot, or any extglob. A match has no more names than its alternative,
/// unless the alternative has `**` (also from `{*,}*`) or an extglob with a
/// `/` in it (`+(x/)`). More alternatives than the policy expands: anywhere.
function reach(glob: string): { hidden: boolean; depth: number } {
  const alternatives = braceAlternatives(glob);
  if (alternatives === null) return { hidden: true, depth: Infinity };
  const all = alternatives.map(normalisedGlob);
  return {
    hidden: all.some((alt) => /(^|\/)(\.|\[[^\]]*\.|[?*+@]\()/.test(alt)),
    depth: all.some((alt) => alt.includes("**") || /\([^)]*\//.test(alt))
      ? Infinity
      : Math.max(...all.map((alt) => alt.split("/").length)),
  };
}

/// A glob with each `\` as a `/`, and without the `.` names and the empty
/// names after the first that `fs.globSync` skips (`.\*.md` and `.//*.md` are
/// `*.md`), as `path.matchesGlob` and `fs.globSync` read it. `[.]` is a `.`:
/// both read a class of one character as that character. A first empty name
/// stays, so `/x` stays absolute and matches no path in the folder. A last
/// name stays: `*/.` and `sub/` name folders, which Glob does not list.
function normalisedGlob(pattern: string): string {
  return pattern.replaceAll("\\", "/").split("/")
    .filter((s, i, all) => i === all.length - 1 || (s !== "." && s !== "[.]" && (s !== "" || i === 0)))
    .join("/");
}

/// The matcher of a normalised glob (`normalisedGlob`) for a path from the
/// root, for Glob and for Grep's `glob`: `path.matchesGlob`. A brace
/// alternative keeps the `.`, `[.]` and empty names in it (`{./a,b}.md`,
/// `{s/[.],x}/c.md`), which `fs.globSync` skips, so each alternative with such
/// a name is matched too, without it (code review 2026-11-15). The policy
/// refuses a pattern whose alternatives it does not expand
/// (`braceAlternatives`). When `fold`, the path and the globs are matched in
/// Unicode NFC, so that `!(café).md` leaves out a name in NFD too, or else
/// both in lower case (`foldedName`). The NFC match keeps each class as
/// given: lower case turns `[Z-a]` into the empty range `[z-a]`, and on macOS
/// `path.matchesGlob` matches a class of more than one character in any
/// letter case itself. The lower-case match takes `[R]`, which
/// `path.matchesGlob` reads as the literal `R` in its exact case (code review
/// 2026-11-15). When `byName`, as for Grep, the file name is matched when no
/// alternative has a `/` (`./b.md`, `{./a,b}.md`), as ripgrep matches a glob
/// without a `/`.
function globMatcher(glob: string, fold: boolean, byName = false): (relative: string) => boolean {
  const alternatives = (braceAlternatives(glob) ?? [glob]).map((alt) => ({ alt, normalised: normalisedGlob(alt) }));
  const changed = alternatives.flatMap(({ alt, normalised }) => (normalised === alt ? [] : [normalised]));
  const globs = [glob, ...changed];
  const name = byName && !alternatives.some(({ normalised }) => normalised.includes("/"));
  const target = (relative: string): string => (name ? path.basename(relative) : relative);
  if (!fold) return (relative) => globs.some((g) => path.matchesGlob(target(relative), g));
  const forms = globs.map((g) => ({ nfc: g.normalize("NFC"), folded: foldedName(g) }));
  return (relative) => {
    const nfc = target(relative).normalize("NFC");
    const folded = foldedName(nfc);
    return forms.some((g) => path.matchesGlob(nfc, g.nfc) || path.matchesGlob(folded, g.folded));
  };
}

/// A name or a glob in lower case and in Unicode NFC, to compare names as a
/// macOS volume finds them: in any letter case by default, and in any Unicode
/// form (a name copied from HFS+ is often in NFD, where a typed one is in
/// NFC).
function foldedName(name: string): string {
  return name.normalize("NFC").toLowerCase();
}

/// On macOS, Glob matches a name in any letter case and Unicode form, also a
/// literal one, as `fs.globSync` did there (code review 2026-11-15); on a
/// case-sensitive volume, `a.md` then lists `A.md` too. Grep's `glob` adds no
/// folding: there `path.matchesGlob` itself ignores letter case in wildcard
/// parts only, where ripgrep's is exact.
const CASE_FOLDS = process.platform === "darwin";

/// The folder under `root` that the pattern's leading literal names give
/// (`sub` for `sub/**/*.md`), in its letter case on disk, or `root` for a
/// pattern with `..`. Each name is found in its folder's listing, when `fold`
/// in any letter case and Unicode form (`foldedName`). Several folders that
/// match, as a case-sensitive volume can hold (`sub` and `SUB`), give the
/// folder that holds them. A name that matches no folder, or only a symlink,
/// gives undefined: the walk enters no symlink, so nothing can match.
function walkStart(root: string, glob: string, fold: boolean): string | undefined {
  const names = glob.split("/").slice(0, -1);
  if (names.includes("..")) return root;
  const literal = names.findIndex((n) => n === "" || /[*?[\]{}()!+@]/.test(n));
  let dir = root;
  for (const name of literal === -1 ? names : names.slice(0, literal)) {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return undefined;
    }
    const folders = entries.filter((e) =>
      e.isDirectory() && (e.name === name || (fold && foldedName(e.name) === foldedName(name)))
    );
    if (folders.length !== 1) return folders.length === 0 ? undefined : dir;
    dir = path.join(dir, folders[0].name);
  }
  return dir;
}

type GrepMode = "files_with_matches" | "content" | "count";

/// Grep, in JavaScript: no search program to find under the profile, and the
/// same results on Linux CI. Like ripgrep, which Claude's Grep runs, it skips
/// hidden files and does not follow symlinks. It walks from the resolved root,
/// so it stays in the folder that the policy judged.
function grep(root: string, args: Record<string, unknown>, policy: SandboxPolicy): FileToolResult {
  const { pattern, glob: filter, output_mode: mode = "files_with_matches" } = args;
  if (typeof pattern !== "string" || pattern === "") return failure("Grep needs a `pattern`.");
  if (filter !== undefined && typeof filter !== "string") return failure("`glob` must be a string.");
  if (mode !== "files_with_matches" && mode !== "content" && mode !== "count") {
    return failure("`output_mode` must be `files_with_matches`, `content` or `count`.");
  }
  let regex: RegExp;
  try {
    regex = new RegExp(pattern, args["-i"] === true ? "i" : "");
  } catch (e) {
    return failure(`The pattern is not a valid regular expression: ${(e as Error).message}`);
  }
  const now = resolvedNow("Grep", root, args, policy);
  if ("failure" in now) return now.failure;
  let rootStat: fs.Stats;
  try {
    rootStat = fs.statSync(now.real);
  } catch (e) {
    return failure(`Grep could not open ${root}: ${reason(e)}.`);
  }
  // A filter is a glob of the path from the root, or of the file name when
  // it holds no `/` after its `.` names are dropped.
  const matches = filter === undefined ? undefined : globMatcher(normalisedGlob(filter), false, true);
  // Each file is read during the walk, before the walk checks its folder, and
  // only content mode keeps its lines (code review 2026-11-15).
  const searched = (file: string): (Found & { count: number; lines: string[] }) | undefined => {
    const content = textOf(file);
    if ("error" in content) return undefined;
    let count = 0;
    const lines: string[] = [];
    linesOf(content.text).forEach((line, i) => {
      if (!regex.test(line)) return;
      count++;
      if (mode === "content") lines.push(`${file}:${i + 1}:${cut(line)}`);
    });
    return count === 0 ? undefined : { file, mtime: content.mtime, count, lines };
  };
  const filtered = (file: string) =>
    matches === undefined || matches(path.relative(now.real, file)) ? searched(file) : undefined;
  const results = rootStat.isDirectory()
    ? walk(now.real, false, filtered)
    : [searched(now.real)].flatMap((r) => (r === undefined ? [] : [r]));
  if (mode === "files_with_matches") return { text: newestFirst(results, "No files found") };
  const lines = results.flatMap((r) => (mode === "count" ? [`${r.file}:${r.count}`] : r.lines));
  return { text: lines.length > 0 ? listed(lines) : "No matches found" };
}

/// What `keep` gives for each regular file under `dir`, a resolved path,
/// `levels` deep at most (1: only the files in `dir`), and for the hidden
/// ones only when `hidden`; undefined leaves a file out. A symlink is neither
/// listed nor entered, and a folder that cannot be read is skipped. So is a
/// folder whose resolved path is not itself after its listing and `keep` on
/// its files: another process swapped it, or a folder above it, for a
/// symlink, so the listing, the stat and the read can be of another folder.
/// The old Glob judged each match for this (code review 2026-11-15). A swap
/// that is undone before the check is not seen (DESIGN.md).
function walk<T>(
  dir: string, hidden: boolean, keep: (file: string) => T | undefined, levels = Infinity, found: T[] = [],
): T[] {
  if (levels < 1) return found;
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return found;
  }
  const kept = found.length;
  const folders: string[] = [];
  for (const entry of entries) {
    if (!hidden && entry.name.startsWith(".")) continue;
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) folders.push(file);
    else if (entry.isFile()) {
      const value = keep(file);
      if (value !== undefined) found.push(value);
    }
  }
  if (!resolvesToItself(dir)) {
    found.length = kept;
    return found;
  }
  for (const folder of folders) walk(folder, hidden, keep, levels - 1, found);
  return found;
}

/// Whether the folder's resolved path is its path.
function resolvesToItself(dir: string): boolean {
  try {
    return fs.realpathSync.native(dir) === dir;
  } catch {
    return false;
  }
}

/// The readable folders that the file lists: a JSON list of strings, as the
/// sidecar writes it before each Codex turn. Any failure gives none, so the
/// tools refuse every path.
export function readFolderList(file: string): string[] {
  try {
    const list: unknown = JSON.parse(fs.readFileSync(file, "utf8"));
    return Array.isArray(list) ? list.filter((f): f is string => typeof f === "string") : [];
  } catch {
    return [];
  }
}

/// What the connector needs to judge a call: the home folder, its working
/// folder and the readable folders of that moment.
export interface ConnectorContext {
  home: string;
  cwd: string;
  folders: () => readonly string[];
}

type Message = { jsonrpc?: string; id?: unknown; method?: unknown; params?: Record<string, unknown> };

/// The reply to one JSON-RPC message from the MCP client, or undefined for a
/// notification. Only `tools` is offered.
export function mcpReply(raw: unknown, ctx: ConnectorContext): object | undefined {
  const msg = (raw !== null && typeof raw === "object" ? raw : {}) as Message;
  if (msg.id === undefined) return undefined;
  const reply = (result: object) => ({ jsonrpc: "2.0", id: msg.id, result });
  switch (msg.method) {
    case "initialize":
      return reply({
        protocolVersion: msg.params?.protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "advisor", version: "1" },
      });
    case "ping":
      return reply({});
    case "tools/list":
      return reply({ tools: FILE_TOOLS });
    case "tools/call": {
      // A failure is the call's error: a throw would end the server, and each
      // later call of the turn with it (code review 2026-11-14).
      let result: FileToolResult;
      try {
        const policy: SandboxPolicy = { home: ctx.home, cwd: ctx.cwd, allowMcpActions: false, readableFolders: ctx.folders() };
        result = fileTool(String(msg.params?.name), msg.params?.arguments ?? {}, policy);
      } catch (e) {
        result = failure(`Advisor's file tool failed: ${e instanceof Error ? e.message : String(e)}`);
      }
      return reply({ content: [{ type: "text", text: result.text }], ...(result.isError ? { isError: true } : {}) });
    }
    default:
      return { jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: `Method not found: ${String(msg.method)}` } };
  }
}
