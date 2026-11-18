import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { AgentSession } from "./agent.js";
import { claudeWriteFolders } from "./claudeSandbox.js";
import { loadReadableFolders } from "./config.js";
import { fakeModelQuery, sse, stubMcp, SYNTHETIC_HOME_ROOT } from "./fakeModel.js";

// The sandbox against the real bundled Claude CLI, not just the policy
// predicates. The SDK approves some calls before `canUseTool` is ever asked —
// reads inside the working directory, allow rules from the user's settings — so
// a predicate-only test can pass while the CLI reads the file anyway (code review
// 2026-10-06). A local fake model endpoint scripts each tool call, and the test
// inspects the tool_result the CLI sends back: the only place a leak shows.
// Everything lives in a synthetic home; no real credentials or network.

const SECRET = "SYNTHETIC_SECRET_CONTENT";
const NOTES = "ORDINARY_NOTES_CONTENT";
const HIDDEN_NAME = "hidden-credential-name";
/// The denylist's refusal. The allowlist refuses most denied paths as well, so
/// "Access denied" alone no longer shows that the denylist works.
const DENYLIST = "non-sensitive file or folder";
/// The allowlist's refusal: the path is in no readable folder.
const NOT_READABLE = "folders that the user lists as readable";
/// An ordinary file in a readable folder that the Grep pattern matches.
const MATCH = "SYNTHETIC_ORDINARY_MATCH";
/// A file in a folder that a test lists as readable only during a session.
const LATER = "SYNTHETIC_LATER_CONTENT";
/// On macOS the CLI runs under a Seatbelt profile (claudeSandbox.ts). The
/// kernel then refuses a file operation that the CLI makes before the tool
/// gate sees the call, such as Glob's `stat` of its folder.
const SEATBELT = process.platform === "darwin";
const KERNEL = "EPERM: operation not permitted";
/// Refused by the tool gate for `reason`, or, before the gate, by the kernel.
const refused = (out: string, reason: string): boolean => out.includes(reason) || (SEATBELT && out.includes(KERNEL));
/// A connector with a tool that reads the file at its `path` argument, as a
/// filesystem connector does. The tool gate does not judge connector
/// arguments; on macOS the kernel does (GHSA-6xc8-f55f-jxqr, fault 2).
const FILES_MCP = `
import fs from "node:fs";
import readline from "node:readline";
const send = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.id === undefined) return;
  if (msg.method === "initialize") {
    send({ jsonrpc: "2.0", id: msg.id, result: {
      protocolVersion: msg.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "files", version: "1" },
    } });
  } else if (msg.method === "tools/list") {
    send({ jsonrpc: "2.0", id: msg.id, result: { tools: [{
      name: "read_file", description: "Read a file", inputSchema: { type: "object", properties: { path: { type: "string" } } },
    }, {
      name: "move_file", description: "Move a file",
      inputSchema: { type: "object", properties: { from: { type: "string" }, to: { type: "string" } } },
    }] } });
  } else if (msg.method === "tools/call" && msg.params.name === "move_file") {
    let text;
    try { fs.renameSync(msg.params.arguments.from, msg.params.arguments.to); text = "MOVED"; } catch (e) { text = "MOVE_FAILED:" + e.code; }
    send({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text }] } });
  } else if (msg.method === "tools/call") {
    let text;
    try { text = "FILE:" + fs.readFileSync(msg.params.arguments.path, "utf8"); } catch (e) { text = "READ_FAILED:" + e.code; }
    send({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text }] } });
  } else {
    send({ jsonrpc: "2.0", id: msg.id, result: {} });
  }
});
`;

let home: string;
let work: string;
let server: http.Server;
let currentCase = "";
/// Tool-use ids must differ within one conversation, and a case can run twice
/// in one session.
let toolUseCount = 0;
const results = new Map<string, string>();
/// The text of the user message that started each case, as the model got it.
const prompts = new Map<string, string>();
const sessions: AgentSession[] = [];

/// Tool call the fake model makes for each case, keyed by the prompt `CASE:<id>`.
function scripted(id: string): { name: string; input: Record<string, unknown> } {
  const p = (...s: string[]) => path.join(home, ...s);
  switch (id) {
    case "notes": return { name: "Read", input: { file_path: p("Documents", "notes.txt") } };
    case "cwdSecret": return { name: "Read", input: { file_path: p(".ssh", "synthetic-key") } };
    case "settingsAllow": return { name: "Read", input: { file_path: p(".claude", "secret.txt") } };
    case "tilde": return { name: "Read", input: { file_path: "~/.ssh/synthetic-key" } };
    case "tildeNotes": return { name: "Read", input: { file_path: "~/Documents/notes.txt" } };
    case "tildeGlob": return { name: "Glob", input: { path: "~/Documents", pattern: "*.txt" } };
    case "globScoped": return { name: "Glob", input: { path: p("Documents"), pattern: "*.txt" } };
    case "globEscape": return { name: "Glob", input: { path: p("Documents"), pattern: p(".ssh", "*") } };
    // Spellings that Node's glob reads as `..` or as an absolute pattern.
    case "globClassDotDot": return { name: "Glob", input: { path: p("Documents"), pattern: "[.][.]/.ssh/*" } };
    case "globBraceAbsolute": return { name: "Glob", input: { path: p("Documents"), pattern: `{x,}${p(".ssh")}/*` } };
    // The user's connectors, as the CLI names them (`mcp__<server>__<tool>`).
    case "mcpRead": return { name: "mcp__stub__lookup", input: {} };
    case "mcpAction": return { name: "mcp__stub__share_file", input: {} };
    case "mcpCompound": return { name: "mcp__stub__findAndReplace", input: {} };
    // GHSA-6xc8-f55f-jxqr: a spelling that APFS folds to `.ssh`, and a store from
    // the extended denylist.
    case "foldedSpelling": return { name: "Read", input: { file_path: "~/.\u017Fsh/synthetic-key" } };
    case "shellHistory": return { name: "Read", input: { file_path: "~/.zsh_history" } };
    case "foldedGlob": return { name: "Glob", input: { path: "~/.\u00DFh", pattern: "*" } };
    case "linkDotDotGlob": return { name: "Glob", input: { path: `${p("Documents")}/k/..`, pattern: "*" } };
    // A symlink followed by `..`, judged in the kernel's form (`k` first) and in
    // the lexical form (`..` first), whichever the CLI opens.
    case "linkDotDot": return { name: "Read", input: { file_path: `${p("Documents")}/k/../synthetic-key` } };
    case "lexicalDotDot": return { name: "Read", input: { file_path: `${p("deep")}/../.ssh/synthetic-key` } };
    // A credential store that the denylist does not name.
    case "unnamedStore": return { name: "Read", input: { file_path: "~/.config/rclone/rclone.conf" } };
    case "unnamedGlob": return { name: "Glob", input: { path: "~/.config/rclone", pattern: "*" } };
    // A search of a readable folder that holds a symlink (`Documents/k`) to a store.
    case "grepLink": return { name: "Grep", input: { path: p("Documents"), pattern: "SYNTHETIC", output_mode: "content" } };
    case "globLink": return { name: "Glob", input: { path: p("Documents"), pattern: "**/*" } };
    // A pattern that names the symlink. The CLI matches a folder in a pattern
    // only after `**/`: `real/*` found nothing in a real folder (seen 2026-11-10).
    case "globLinkNamed": return { name: "Glob", input: { path: p("Documents"), pattern: "**/k/*" } };
    case "grepLinkNamed": return {
      name: "Grep", input: { path: p("Documents"), pattern: "SYNTHETIC", glob: "**/k/*", output_mode: "content" },
    };
    // The same patterns for a real folder, as a control: they do match.
    case "globRealNamed": return { name: "Glob", input: { path: p("Documents"), pattern: "**/real/*" } };
    // A connector's path argument, which only the kernel judges.
    case "connectorStore": return { name: "mcp__files__read_file", input: { path: p(".config", "rclone", "rclone.conf") } };
    case "connectorNotes": return { name: "mcp__files__read_file", input: { path: p("Documents", "notes.txt") } };
    case "connectorKeychain": return { name: "mcp__files__read_file", input: { path: p("Library", "Keychains", "login.keychain-db") } };
    // A store moved into a readable folder could be read there.
    case "connectorMove": return { name: "mcp__files__move_file", input: { from: p(".ssh"), to: p("Documents", "moved") } };
    // A file in a folder that becomes readable during the session.
    case "laterPlan": return { name: "Read", input: { file_path: p("later", "plan.txt") } };
    case "grepRealNamed": return {
      name: "Grep", input: { path: p("Documents"), pattern: "SYNTHETIC", glob: "**/real/*", output_mode: "content" },
    };
    default: throw new Error(`no script for ${id}`);
  }
}

type Block = { type: string; text?: string; content?: unknown };
type Message = { role: string; content: string | Block[] };

/// Fake Messages API: a prompt `CASE:<id>` gets that case's tool call; the
/// follow-up request carrying its tool_result is recorded and answered "done".
function handle(req: http.IncomingMessage, res: http.ServerResponse, raw: string): void {
  if (!req.url?.startsWith("/v1/messages")) {
    res.writeHead(200, { "content-type": "application/json" });
    res.end("{}");
    return;
  }
  const body = JSON.parse(raw) as { messages?: Message[]; tools?: unknown[] };
  const users = (body.messages ?? []).filter((m) => m.role === "user");
  const last = users[users.length - 1];
  const blocks: Block[] = typeof last?.content === "string"
    ? [{ type: "text", text: last.content }]
    : last?.content ?? [];
  const toolResult = blocks.find((b) => b.type === "tool_result");
  if (toolResult) {
    results.set(currentCase, JSON.stringify(toolResult.content));
    sse(res, [{ type: "text", text: "done" }], "end_turn");
    return;
  }
  const text = blocks.map((b) => b.text ?? "").join("\n");
  const id = text.match(/CASE:(\w+)/)?.[1];
  if (id && body.tools) {
    currentCase = id;
    prompts.set(id, text);
    const call = scripted(id);
    sse(res, [{ type: "tool_use", id: `toolu_${id}_${++toolUseCount}`, ...call }], "tool_use");
    return;
  }
  sse(res, [{ type: "text", text: "ok" }], "end_turn");
}

before(async () => {
  // Not in a temp folder: the profile lets the CLI write the temp folders, and
  // the tests check that it cannot write the home folder.
  home = fs.realpathSync(fs.mkdtempSync(path.join(SYNTHETIC_HOME_ROOT, "advisor-sdk-sb-")));
  work = path.join(home, "work");
  for (const dir of [
    ".ssh", ".ssh/sub", ".claude", ".config", ".config/rclone", "Documents", "Documents/real", "work", "work/sub",
    "later", "connectors", "Library", "Library/Keychains",
  ]) {
    fs.mkdirSync(path.join(home, dir));
  }
  fs.symlinkSync(path.join(home, ".ssh", "sub"), path.join(home, "Documents", "k"));
  fs.symlinkSync(path.join(home, "work", "sub"), path.join(home, "deep"));
  fs.writeFileSync(path.join(home, ".ssh", "synthetic-key"), SECRET);
  fs.writeFileSync(path.join(home, ".ssh", HIDDEN_NAME), SECRET);
  fs.writeFileSync(path.join(home, ".ssh", "sub", HIDDEN_NAME), SECRET);
  fs.writeFileSync(path.join(home, ".claude", "secret.txt"), SECRET);
  fs.writeFileSync(path.join(home, ".zsh_history"), SECRET);
  fs.writeFileSync(path.join(home, ".config", "rclone", "rclone.conf"), SECRET);
  fs.writeFileSync(path.join(home, "Documents", "notes.txt"), NOTES);
  fs.writeFileSync(path.join(home, "Documents", "match.md"), MATCH);
  fs.writeFileSync(path.join(home, "Documents", "real", "inner.md"), MATCH);
  fs.writeFileSync(path.join(home, "later", "plan.txt"), LATER);
  fs.writeFileSync(path.join(home, "Library", "Keychains", "login.keychain-db"), SECRET);
  // The user's own settings allow a path the denylist refuses — the shape found
  // in a real ~/.claude/settings.json (`Read(~/.claude/**)`).
  fs.writeFileSync(
    path.join(home, ".claude", "settings.json"),
    JSON.stringify({ permissions: { allow: [`Read(/${path.join(home, ".claude")}/**)`] } })
  );
  server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => handle(req, res, raw));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
});

after(() => {
  for (const s of sessions) s.reset();
  server.close();
  fs.rmSync(home, { recursive: true, force: true });
});

/// A session whose CLI runs in the synthetic home against the fake endpoint.
/// `~/Documents` and `~/work` are readable unless a test lists other folders.
/// The policy reads the list at each call, as it reads config.json.
function session(cwd: string, readable = ["Documents", "work"].map((d) => path.join(home, d)), allowMcpActions = false): AgentSession {
  const { port } = server.address() as { port: number };
  const queryFn = fakeModelQuery(home, port);
  const s = new AgentSession(
    {
      name: "sdk-sandbox", systemPrompt: "test", model: "claude-test", allowedTools: ["WebSearch", "WebFetch"],
      // A new list at each call, as a read of config.json gives.
      cwd, home, allowMcpActions, readableFolders: () => [...readable],
    },
    queryFn
  );
  sessions.push(s);
  return s;
}

async function toolResult(s: AgentSession, id: string): Promise<string> {
  results.delete(id); // a case that runs twice must not see its earlier result
  const r = await s.run(`CASE:${id}`, undefined, 30_000);
  assert.equal(r.error, undefined, `${id}: ${r.error}`);
  const out = results.get(id);
  assert.ok(out !== undefined, `${id}: the CLI never returned a tool result`);
  return out;
}

test("#session-history Claude reads a previous session from the configured archive without a Files allowance", async () => {
  const file = path.join(home, "history-config.json");
  fs.writeFileSync(file, JSON.stringify({ readableFolders: [], sessionDir: path.join(home, "later") }));
  const s = session(work, loadReadableFolders(file));
  assert.ok((await toolResult(s, "laterPlan")).includes(LATER));
  assert.ok(!(await toolResult(s, "unnamedStore")).includes(SECRET));
});

test("#sandbox-sdk-gate harness control: an ordinary file reaches the model", async () => {
  const out = await toolResult(session(work), "notes");
  assert.ok(out.includes(NOTES), out);
});

test("#sandbox-sdk-gate a denied file inside the working directory is not read", async () => {
  const out = await toolResult(session(home), "cwdSecret");
  assert.ok(!out.includes(SECRET), out);
  assert.ok(out.includes(DENYLIST), out);
});

test("#sandbox-sdk-gate a user-settings allow rule cannot open a denied path", async () => {
  const out = await toolResult(session(work), "settingsAllow");
  assert.ok(!out.includes(SECRET), out);
  assert.ok(out.includes(DENYLIST), out);
});

test("#sandbox-sdk-gate a ~ path cannot reach a denied file", async () => {
  const out = await toolResult(session(work), "tilde");
  assert.ok(!out.includes(SECRET), out);
  assert.ok(out.includes(DENYLIST), out);
});

test("#sandbox-glob-pattern harness control: a scoped Glob lists its files", async () => {
  const out = await toolResult(session(work), "globScoped");
  assert.ok(out.includes("notes.txt"), out);
});

test("#sandbox-glob-pattern an absolute pattern cannot search outside its checked root", async () => {
  const out = await toolResult(session(work), "globEscape");
  assert.ok(!out.includes(HIDDEN_NAME), out);
});

test("#sandbox-glob-pattern the gate refuses a pattern that spells `..` or `/` another way", async () => {
  // The CLI 2.1.173 itself lists nothing for these (probe, 2026-11-14); the
  // gate refuses them as Advisor's own Glob does.
  for (const id of ["globClassDotDot", "globBraceAbsolute"]) {
    const out = await toolResult(session(work), id);
    assert.ok(out.includes("patterns must be relative"), `${id}: ${out}`);
    assert.ok(!out.includes(HIDDEN_NAME), `${id}: ${out}`);
  }
});

test("#sandbox-fold-spelling a spelling that the filesystem folds to a denied path is not read", async (t) => {
  if (!fs.existsSync(path.join(home, ".ſsh"))) return t.skip("this filesystem does not fold names");
  const out = await toolResult(session(work), "foldedSpelling");
  assert.ok(!out.includes(SECRET), out);
  assert.ok(out.includes(DENYLIST), out);
  // A Glob `path` takes another route to the gate (unexpanded), and `.ßh` is
  // another folded spelling.
  if (!fs.existsSync(path.join(home, ".\u00DFh"))) return t.skip("this filesystem does not fold ß");
  const glob = await toolResult(session(work), "foldedGlob");
  assert.ok(!glob.includes(HIDDEN_NAME), glob);
  assert.ok(refused(glob, DENYLIST), glob);
});

test("#sandbox-credential-stores a credential store from the extended list is not read", async () => {
  const out = await toolResult(session(work), "shellHistory");
  assert.ok(!out.includes(SECRET), out);
  assert.ok(out.includes(DENYLIST), out);
});

test("#sandbox-symlink-read a symlink followed by .. cannot reach a denied file", async () => {
  // The CLI normalises a Read path before the gate (seen 2026-11-10), so it
  // opens the lexical form: `~/.ssh/…` for `deep/../.ssh/…`, which the gate
  // denies, and the missing `Documents/synthetic-key` for `k/../…`. A CLI that
  // stopped normalising would open the kernel's form, which the gate denies.
  const lexical = await toolResult(session(work), "lexicalDotDot");
  assert.ok(!lexical.includes(SECRET), lexical);
  assert.ok(lexical.includes(DENYLIST), lexical);
  const link = await toolResult(session(work), "linkDotDot");
  assert.ok(!link.includes(SECRET), link);
  assert.ok(link.includes(DENYLIST) || link.includes("File does not exist"), link);
  // A Glob `path` with `k/..`: the kernel's form is `~/.ssh`. The CLI also
  // normalises a Glob path before it searches (seen 2026-11-10), so the old
  // gate's allow listed `Documents`, not `~/.ssh`: the deny is a second layer.
  const glob = await toolResult(session(work), "linkDotDotGlob");
  assert.ok(!glob.includes(HIDDEN_NAME), glob);
  assert.ok(glob.includes(DENYLIST), glob);
});

test("#sandbox-readable-folders a credential store outside every readable folder is not read", async () => {
  // `~/.config/rclone` is in no named store: only the allowlist refuses it.
  const read = await toolResult(session(work), "unnamedStore");
  assert.ok(!read.includes(SECRET), read);
  assert.ok(read.includes(NOT_READABLE), read);
  const glob = await toolResult(session(work), "unnamedGlob");
  assert.ok(!glob.includes("rclone.conf"), glob);
  assert.ok(refused(glob, NOT_READABLE), glob);
});

// The CLI's Seatbelt profile is fixed when it starts. An idle session starts a
// new CLI after the list changes, so a folder that the user adds is readable
// at the next task, not only at the next recording (decided 2026-11-11).
test("#claude-seatbelt a folder added during a session is read at the next task", async () => {
  const readable = [path.join(home, "Documents")];
  const s = session(work, readable);
  const before = await toolResult(s, "notes");
  assert.ok(before.includes(NOTES), before);
  readable.push(path.join(home, "later"));
  const after = await toolResult(s, "laterPlan");
  assert.ok(after.includes(LATER), after);
});

// Fault 2: a connector reads with the rights of its own process, and the tool
// gate does not judge its arguments. Under the CLI's Seatbelt profile, the
// connector inherits the readable folders.
test("#claude-seatbelt a connector cannot read a file outside the readable folders", { skip: !SEATBELT && "requires macOS Seatbelt" }, async (t) => {
  const connectors = path.join(home, "connectors");
  const userConfig = path.join(home, ".claude", ".claude.json");
  fs.writeFileSync(path.join(connectors, "files-mcp.mjs"), FILES_MCP);
  fs.writeFileSync(userConfig, JSON.stringify({
    mcpServers: { files: { type: "stdio", command: process.execPath, args: [path.join(connectors, "files-mcp.mjs")] } },
  }));
  t.after(() => fs.rmSync(userConfig, { force: true }));
  // "Allow connector actions" on: the kernel, not the tool gate, refuses the move.
  const s = session(work, [path.join(home, "Documents"), connectors], true);
  const notes = await toolResult(s, "connectorNotes");
  assert.ok(notes.includes(`FILE:${NOTES}`), notes);
  const store = await toolResult(s, "connectorStore");
  assert.ok(!store.includes(SECRET), store);
  assert.ok(store.includes("READ_FAILED:EPERM"), store);
  // The CLI here has an API key in its environment, so it needs no keychain,
  // and the profile keeps it refused.
  const keychain = await toolResult(s, "connectorKeychain");
  assert.ok(!keychain.includes(SECRET), keychain);
  assert.ok(keychain.includes("READ_FAILED:EPERM"), keychain);
  // Writes are confined, so a connector cannot move a store into a readable
  // folder to read it there (code review 2026-11-14).
  const move = await toolResult(s, "connectorMove");
  assert.ok(move.includes("MOVE_FAILED:EPERM"), move);
  assert.ok(fs.existsSync(path.join(home, ".ssh", "synthetic-key")));
});

// The CLI saves its transcript in its own folder, which the profile lets it
// write. A CLI release that names the folder another way would lose the
// transcripts without an error, so this checks the name (2026-11-14).
test("#claude-seatbelt the CLI writes its transcript under the profile", { skip: !SEATBELT && "requires macOS Seatbelt" }, async () => {
  const s = session(work);
  await toolResult(s, "notes");
  const [transcripts] = claudeWriteFolders(home, work, path.join(home, ".claude"));
  assert.ok(fs.readdirSync(transcripts).some((f) => f.endsWith(".jsonl")), transcripts);
});

test("#sandbox-readable-folders an ordinary file is not read when no folder is listed, or only the home folder", async () => {
  // The home folder holds denied paths, so a list of only `~` reads nothing.
  for (const readable of [[], [home]]) {
    const out = await toolResult(session(work, readable), "notes");
    assert.ok(!out.includes(NOTES), out);
    assert.ok(out.includes(NOT_READABLE), out);
  }
});

test("#sandbox-readable-folders a folder removed from the list is refused at once, in a live session", async () => {
  const readable = [path.join(home, "Documents")];
  const s = session(work, readable);
  const before = await toolResult(s, "notes");
  assert.ok(before.includes(NOTES), before);
  readable.length = 0; // the user removes the folder; the CLI keeps running
  // A changed file: the CLI answers a repeated Read of an unchanged one
  // without its content, so an allowed Read would then show nothing.
  fs.appendFileSync(path.join(home, "Documents", "notes.txt"), "\n");
  const after = await toolResult(s, "notes");
  assert.ok(!after.includes(NOTES), after);
  assert.ok(after.includes(NOT_READABLE), after);
});

// The model learns the readable folders from the task and from each refusal
// of a local path, as the CLI passes them on (2026-11-11). A folder that the
// policy refuses is not named.
test("#sandbox-readable-folders the model gets the readable folders in the task and in a refusal", async () => {
  const documents = path.join(home, "Documents");
  const named = `: ${JSON.stringify(documents)}.`;
  const refused = await toolResult(session(work, [documents, "~/.ssh"]), "unnamedStore");
  assert.ok(refused.includes(NOT_READABLE), refused);
  assert.ok(refused.includes(JSON.stringify(named).slice(1, -1)), refused);
  const task = prompts.get("unnamedStore") ?? "";
  assert.ok(task.includes(`Advisor lets you read local files only inside these folders${named}`), task);
  assert.ok(!task.includes(".ssh"), task);
});

test("#sandbox-readable-folders a search of a readable folder does not follow a symlink out of it", async () => {
  // The policy checks the search root only. The CLI's search does not follow
  // `Documents/k -> ~/.ssh/sub` (seen 2026-11-10), and the policy relies on it.
  const grep = await toolResult(session(work), "grepLink");
  assert.ok(grep.includes(MATCH), grep); // the search ran
  assert.ok(!grep.includes(SECRET), grep);
  const glob = await toolResult(session(work), "globLink");
  assert.ok(glob.includes("notes.txt"), glob);
  assert.ok(!glob.includes(HIDDEN_NAME), glob);
  // Nor when the pattern names the symlink.
  // The same patterns match in a real folder, so `k/*` would match if the
  // search followed `k`.
  // The pattern is what filters: the files beside `real` are not listed.
  const globReal = await toolResult(session(work), "globRealNamed");
  assert.ok(globReal.includes("real/inner.md"), globReal);
  assert.ok(!globReal.includes("notes.txt") && !globReal.includes("match.md"), globReal);
  const grepReal = await toolResult(session(work), "grepRealNamed");
  assert.ok(grepReal.includes(`real/inner.md:1:${MATCH}`), grepReal);
  assert.ok(!grepReal.includes("match.md"), grepReal);
  // The searches run and find nothing (seen 2026-11-10): not refused, and not
  // failed for some other reason.
  const globNamed = await toolResult(session(work), "globLinkNamed");
  assert.ok(!globNamed.includes(HIDDEN_NAME), globNamed);
  assert.ok(globNamed.includes("No files found"), globNamed);
  const grepNamed = await toolResult(session(work), "grepLinkNamed");
  assert.ok(!grepNamed.includes(SECRET), grepNamed);
  assert.ok(grepNamed.includes("No matches found"), grepNamed);
});

test("#sandbox-explicit-paths a ~ path to an ordinary file still reaches the model", async () => {
  // Agents take paths like ~/Notes from the user's CLAUDE.md. The CLI expands ~
  // itself, so refusing relative paths must not break these.
  const read = await toolResult(session(work), "tildeNotes");
  assert.ok(read.includes(NOTES), read);
  const glob = await toolResult(session(work), "tildeGlob");
  assert.ok(glob.includes("notes.txt"), glob);
});

// The connector gate against the real CLI: the tool names must reach the
// PreToolUse hook in the `mcp__<server>__<tool>` shape, casing intact, for
// `mcpPermission`'s word splitting to mean anything. Connector actions are off
// (the AgentSession default), so the read tool runs and the action tools do not.
test("#sandbox-mcp-gate a connector read tool runs; a sharing tool and a compound name do not", async (t) => {
  // A user-scope connector with a read tool and two action tools, as
  // `claude mcp add --scope user` writes it — registered for this test only, so
  // the path cases above don't each spawn a server they never use.
  // In a readable folder: on macOS the connector inherits the CLI's Seatbelt
  // profile, and could not read its own script elsewhere in the home folder.
  const connectors = path.join(home, "connectors");
  const stub = path.join(connectors, "stub-mcp.mjs");
  const userConfig = path.join(home, ".claude", ".claude.json");
  fs.writeFileSync(stub, stubMcp(["lookup", "share_file", "findAndReplace"]));
  fs.writeFileSync(userConfig, JSON.stringify({
    mcpServers: { stub: { type: "stdio", command: process.execPath, args: [stub] } },
  }));
  t.after(() => fs.rmSync(userConfig, { force: true }));
  const s = session(work, [path.join(home, "Documents"), path.join(home, "work"), connectors]);
  const read = await toolResult(s, "mcpRead");
  assert.ok(read.includes("STUB_TOOL_RAN:lookup"), read);
  for (const id of ["mcpAction", "mcpCompound"]) {
    const out = await toolResult(s, id);
    assert.ok(!out.includes("STUB_TOOL_RAN"), `${id}: ${out}`);
    assert.ok(out.includes("not an allowed read/search connector tool"), `${id}: ${out}`);
  }
});
