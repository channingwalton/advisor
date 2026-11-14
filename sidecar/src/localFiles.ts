import fs from "node:fs";
import path from "node:path";
import { absolutePath, toolDecision, type SandboxPolicy } from "./toolPolicy.js";

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
      "`pattern` is relative to it, such as `**/*.md`. Returns paths, newest first.",
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

/// Glob, from the resolved root. A match with a `..` segment is left out (a
/// backslash is a character of a name on macOS and Linux, not a separator):
/// `fs.globSync` takes `[.][.]` as `..`, which the policy's check of the
/// pattern's text does not see (code review 2026-11-14). A pattern can go
/// through a symlink (`link/*`), so a match that Read would refuse is left out
/// too. A match whose resolved path is itself has no symlink in it, so it is
/// in the folder that the policy allowed, which can hold no store
/// (`readableRoots`). Only the other matches are judged as a Read of them
/// would be: the full judgement resolves each store's path, and took 20 s for
/// 10,000 notes.
function glob(root: string, args: Record<string, unknown>, policy: SandboxPolicy): FileToolResult {
  const { pattern } = args;
  if (typeof pattern !== "string" || pattern === "") return failure("Glob needs a `pattern`, such as `**/*.md`.");
  const now = resolvedNow("Glob", root, args, policy);
  if ("failure" in now) return now.failure;
  const realRoot = now.real;
  let matches: string[];
  try {
    matches = fs.globSync(pattern, { cwd: realRoot });
  } catch (e) {
    return failure(`Glob could not search ${root}: ${reason(e)}.`);
  }
  const files = matches.flatMap((match) => {
    if (match.split("/").includes("..")) return [];
    const file = path.join(realRoot, match);
    try {
      const direct = fs.realpathSync.native(file) === file;
      if (!direct && toolDecision("Read", { file_path: file }, policy).behavior === "deny") return [];
      const stat = fs.statSync(file);
      return stat.isFile() ? [{ file, mtime: stat.mtimeMs }] : [];
    } catch {
      return [];
    }
  });
  return { text: newestFirst(files, "No files found") };
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
  const files = rootStat.isDirectory() ? walk(now.real, now.real, filter) : [now.real];
  const found: { file: string; mtime: number }[] = [];
  const lines: string[] = [];
  for (const file of files) {
    const content = textOf(file);
    if ("error" in content) continue;
    const hits = linesOf(content.text).flatMap((line, i) => (regex.test(line) ? [{ n: i + 1, line }] : []));
    if (hits.length === 0) continue;
    if (mode === "files_with_matches") found.push({ file, mtime: content.mtime });
    else if (mode === "count") lines.push(`${file}:${hits.length}`);
    else lines.push(...hits.map((h) => `${file}:${h.n}:${cut(h.line)}`));
  }
  if (mode === "files_with_matches") return { text: newestFirst(found, "No files found") };
  return { text: lines.length > 0 ? listed(lines) : "No matches found" };
}

/// The regular files under `dir`: no hidden names, no symlinks, and only those
/// that match `filter` (a glob of the file name, or of the path from `root`
/// when the glob holds a `/`). A folder that cannot be read is skipped.
function walk(root: string, dir: string, filter: string | undefined): string[] {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries.flatMap((entry) => {
    if (entry.name.startsWith(".")) return [];
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) return walk(root, file, filter);
    if (!entry.isFile()) return [];
    if (filter === undefined) return [file];
    const subject = filter.includes("/") ? path.relative(root, file) : entry.name;
    return path.matchesGlob(subject, filter) ? [file] : [];
  });
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
