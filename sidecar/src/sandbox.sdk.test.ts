import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { AgentSession } from "./agent.js";
import { fakeModelQuery, sse, stubMcp } from "./fakeModel.js";

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

let home: string;
let work: string;
let server: http.Server;
let currentCase = "";
const results = new Map<string, string>();
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
  const id = blocks.map((b) => b.text ?? "").join("\n").match(/CASE:(\w+)/)?.[1];
  if (id && body.tools) {
    currentCase = id;
    const call = scripted(id);
    sse(res, [{ type: "tool_use", id: `toolu_${id}`, ...call }], "tool_use");
    return;
  }
  sse(res, [{ type: "text", text: "ok" }], "end_turn");
}

before(async () => {
  home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-sdk-sb-")));
  work = path.join(home, "work");
  for (const dir of [".ssh", ".ssh/sub", ".claude", "Documents", "work", "work/sub"]) fs.mkdirSync(path.join(home, dir));
  fs.symlinkSync(path.join(home, ".ssh", "sub"), path.join(home, "Documents", "k"));
  fs.symlinkSync(path.join(home, "work", "sub"), path.join(home, "deep"));
  fs.writeFileSync(path.join(home, ".ssh", "synthetic-key"), SECRET);
  fs.writeFileSync(path.join(home, ".ssh", HIDDEN_NAME), SECRET);
  fs.writeFileSync(path.join(home, ".claude", "secret.txt"), SECRET);
  fs.writeFileSync(path.join(home, ".zsh_history"), SECRET);
  fs.writeFileSync(path.join(home, "Documents", "notes.txt"), NOTES);
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
function session(cwd: string): AgentSession {
  const { port } = server.address() as { port: number };
  const queryFn = fakeModelQuery(home, port);
  const s = new AgentSession(
    { name: "sdk-sandbox", systemPrompt: "test", model: "claude-test", allowedTools: ["WebSearch", "WebFetch"], cwd, home },
    queryFn
  );
  sessions.push(s);
  return s;
}

async function toolResult(s: AgentSession, id: string): Promise<string> {
  const r = await s.run(`CASE:${id}`, undefined, 30_000);
  assert.equal(r.error, undefined, `${id}: ${r.error}`);
  const out = results.get(id);
  assert.ok(out !== undefined, `${id}: the CLI never returned a tool result`);
  return out;
}

test("#sandbox-sdk-gate harness control: an ordinary file reaches the model", async () => {
  const out = await toolResult(session(work), "notes");
  assert.ok(out.includes(NOTES), out);
});

test("#sandbox-sdk-gate a denied file inside the working directory is not read", async () => {
  const out = await toolResult(session(home), "cwdSecret");
  assert.ok(!out.includes(SECRET), out);
});

test("#sandbox-sdk-gate a user-settings allow rule cannot open a denied path", async () => {
  const out = await toolResult(session(work), "settingsAllow");
  assert.ok(!out.includes(SECRET), out);
});

test("#sandbox-sdk-gate a ~ path cannot reach a denied file", async () => {
  const out = await toolResult(session(work), "tilde");
  assert.ok(!out.includes(SECRET), out);
});

test("#sandbox-glob-pattern harness control: a scoped Glob lists its files", async () => {
  const out = await toolResult(session(work), "globScoped");
  assert.ok(out.includes("notes.txt"), out);
});

test("#sandbox-glob-pattern an absolute pattern cannot search outside its checked root", async () => {
  const out = await toolResult(session(work), "globEscape");
  assert.ok(!out.includes(HIDDEN_NAME), out);
});

test("#sandbox-fold-spelling a spelling that the filesystem folds to a denied path is not read", async (t) => {
  if (!fs.existsSync(path.join(home, ".ſsh"))) return t.skip("this filesystem does not fold names");
  const out = await toolResult(session(work), "foldedSpelling");
  assert.ok(!out.includes(SECRET), out);
  assert.ok(out.includes("Access denied"), out);
  // A Glob `path` takes another route to the gate (unexpanded), and `.ßh` is
  // another folded spelling.
  if (!fs.existsSync(path.join(home, ".\u00DFh"))) return t.skip("this filesystem does not fold ß");
  const glob = await toolResult(session(work), "foldedGlob");
  assert.ok(!glob.includes(HIDDEN_NAME), glob);
  assert.ok(glob.includes("Access denied"), glob);
});

test("#sandbox-credential-stores a credential store from the extended list is not read", async () => {
  const out = await toolResult(session(work), "shellHistory");
  assert.ok(!out.includes(SECRET), out);
  assert.ok(out.includes("Access denied"), out);
});

test("#sandbox-symlink-read a symlink followed by .. cannot reach a denied file", async () => {
  // The CLI normalises a Read path before the gate (seen 2026-11-10), so it
  // opens the lexical form: `~/.ssh/…` for `deep/../.ssh/…`, which the gate
  // denies, and the missing `Documents/synthetic-key` for `k/../…`. A CLI that
  // stopped normalising would open the kernel's form, which the gate denies.
  const lexical = await toolResult(session(work), "lexicalDotDot");
  assert.ok(!lexical.includes(SECRET), lexical);
  assert.ok(lexical.includes("Access denied"), lexical);
  const link = await toolResult(session(work), "linkDotDot");
  assert.ok(!link.includes(SECRET), link);
  assert.ok(link.includes("Access denied") || link.includes("File does not exist"), link);
  // A Glob `path` with `k/..`: the kernel's form is `~/.ssh`. The CLI also
  // normalises a Glob path before it searches (seen 2026-11-10), so the old
  // gate's allow listed `Documents`, not `~/.ssh`: the deny is a second layer.
  const glob = await toolResult(session(work), "linkDotDotGlob");
  assert.ok(!glob.includes(HIDDEN_NAME), glob);
  assert.ok(glob.includes("Access denied"), glob);
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
  const stub = path.join(home, "stub-mcp.mjs");
  const userConfig = path.join(home, ".claude", ".claude.json");
  fs.writeFileSync(stub, stubMcp(["lookup", "share_file", "findAndReplace"]));
  fs.writeFileSync(userConfig, JSON.stringify({
    mcpServers: { stub: { type: "stdio", command: process.execPath, args: [stub] } },
  }));
  t.after(() => fs.rmSync(userConfig, { force: true }));
  const s = session(work);
  const read = await toolResult(s, "mcpRead");
  assert.ok(read.includes("STUB_TOOL_RAN:lookup"), read);
  for (const id of ["mcpAction", "mcpCompound"]) {
    const out = await toolResult(s, id);
    assert.ok(!out.includes("STUB_TOOL_RAN"), `${id}: ${out}`);
    assert.ok(out.includes("not an allowed read/search connector tool"), `${id}: ${out}`);
  }
});
