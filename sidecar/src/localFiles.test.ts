import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";
import { FILE_TOOLS, fileTool, mcpReply, readFolderList, type FileToolResult } from "./localFiles.js";
import { toolDecision, type SandboxPolicy } from "./toolPolicy.js";

// Advisor's own file tools for Codex card lanes (#120), against real files in
// a synthetic home. The Codex Seatbelt profile that the connector also runs
// under is tested with the real CLI in codex.sdk.test.ts.

let home: string;
let notes: string;
const SECRET = "PRIVATE KEY 120";
let policy: SandboxPolicy;

before(() => {
  home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-files-")));
  notes = path.join(home, "Notes");
  fs.mkdirSync(path.join(notes, "sub"), { recursive: true });
  fs.mkdirSync(path.join(home, ".ssh"));
  fs.mkdirSync(path.join(home, ".codex"));
  fs.mkdirSync(path.join(home, "Other"));
  fs.writeFileSync(path.join(notes, "a.md"), "alpha\nbeta\nGamma\n");
  fs.writeFileSync(path.join(notes, "sub", "b.md"), "beta two\n");
  fs.writeFileSync(path.join(notes, "bin.dat"), Buffer.from([0x61, 0x00, 0x62]));
  fs.writeFileSync(path.join(home, ".ssh", "id_test"), `${SECRET}\n`);
  fs.writeFileSync(path.join(home, ".codex", "auth.json"), `${SECRET}\n`);
  fs.writeFileSync(path.join(home, "Other", "c.md"), `${SECRET}\n`);
  fs.symlinkSync(path.join(home, ".ssh"), path.join(notes, "link"));
  fs.symlinkSync(path.join(home, ".ssh", "id_test"), path.join(notes, "key-link.md"));
  // a.md is the newest note, so Glob lists it first.
  fs.utimesSync(path.join(notes, "sub", "b.md"), 1_000, 1_000);
  fs.utimesSync(path.join(notes, "a.md"), 2_000, 2_000);
  policy = { home, cwd: path.join(home, "cwd"), allowMcpActions: false, readableFolders: [notes] };
});

after(() => fs.rmSync(home, { recursive: true, force: true }));

/// A refusal: an error that holds no secret and names the readable folder.
function assertRefused(r: FileToolResult, what: string): void {
  assert.equal(r.isError, true, `${what}: ${r.text}`);
  assert.ok(!r.text.includes(SECRET), `${what}: ${r.text}`);
  assert.ok(r.text.includes(JSON.stringify(notes)), `${what} names the readable folders: ${r.text}`);
}

test("#codex-files Read returns an allowed note's lines, numbered", () => {
  const r = fileTool("Read", { file_path: path.join(notes, "a.md") }, policy);
  assert.equal(r.isError, undefined, r.text);
  assert.equal(r.text, "     1\talpha\n     2\tbeta\n     3\tGamma");
});

test("#codex-files Read takes part of a note with offset and limit, and says what is left", () => {
  const r = fileTool("Read", { file_path: "~/Notes/a.md", offset: 2, limit: 1 }, policy);
  assert.equal(r.isError, undefined, r.text);
  assert.match(r.text, /^ {5}2\tbeta\n/);
  assert.match(r.text, /lines 2–2 of 3/);
  assert.match(r.text, /offset 3/);
  assert.equal(fileTool("Read", { file_path: path.join(notes, "a.md"), offset: 0 }, policy).isError, true);
});

test("#codex-files Read refuses a store, an unlisted folder and a symlink out of a readable folder", () => {
  for (const file of [
    path.join(home, ".ssh", "id_test"),
    "~/.ssh/id_test",
    path.join(home, ".codex", "auth.json"),
    path.join(home, "Other", "c.md"),
    path.join(notes, "key-link.md"),
    path.join(notes, "link", "id_test"),
    path.join(notes, "..", "Other", "c.md"),
    "Notes/a.md",
  ]) {
    assertRefused(fileTool("Read", { file_path: file }, policy), file);
  }
});

test("#codex-files Read gives an error for a folder and for a binary file", () => {
  assert.match(fileTool("Read", { file_path: notes }, policy).text, /folder.*Glob/);
  assert.equal(fileTool("Read", { file_path: notes }, policy).isError, true);
  assert.match(fileTool("Read", { file_path: path.join(notes, "bin.dat") }, policy).text, /binary/);
});

test("#codex-files Glob lists the files in a readable folder, newest first", () => {
  const r = fileTool("Glob", { path: notes, pattern: "**/*.md" }, policy);
  assert.equal(r.isError, undefined, r.text);
  assert.deepEqual(r.text.split("\n"), [path.join(notes, "a.md"), path.join(notes, "sub", "b.md")]);
  // A pattern that starts with a folder name works too.
  assert.equal(fileTool("Glob", { path: notes, pattern: "sub/*.md" }, policy).text, path.join(notes, "sub", "b.md"));
});

test("#codex-files Glob lists no file that Read would refuse", () => {
  // `key-link.md` matches, and `link/*` goes through a symlink into `~/.ssh`.
  assert.ok(!fileTool("Glob", { path: notes, pattern: "*" }, policy).text.includes("key-link"));
  assert.equal(fileTool("Glob", { path: notes, pattern: "link/*" }, policy).text, "No files found");
});

test("#codex-files Glob refuses a pattern or a path that leaves the readable folders", () => {
  for (const input of [
    { path: notes, pattern: path.join(home, ".ssh", "*") },
    { path: notes, pattern: "~/.ssh/*" },
    { path: notes, pattern: "../Other/*" },
    { path: notes, pattern: "{*.md,/etc/*}" },
    { path: home, pattern: "**/*" },
    { path: path.join(home, "Other"), pattern: "*" },
    { pattern: "**/*.md" },
  ]) {
    assertRefused(fileTool("Glob", input, policy), JSON.stringify(input));
  }
  assert.equal(fileTool("Glob", { path: notes }, policy).isError, true);
});

test("#codex-files Glob refuses a pattern that spells `..` or `/` another way", () => {
  // `fs.globSync` takes `[.][.]` as `..`, and `\` and `{x,}` before an
  // absolute path as an absolute pattern (code review and probe, 2026-11-14).
  for (const pattern of [
    "[.][.]/Other/*", "[.][.]/.ssh/*", "sub/[.][.]/[.][.]/Other/*", "{.,x}./Other/*", "[.]{.,}/Other/*", "[.]./Other/*",
    `\\${home}/Other/*`, `\\.${home}/Other/*`, `{x,}${home}/Other/*`, "x\\[.][.]\\Other/*",
  ]) {
    assertRefused(fileTool("Glob", { path: notes, pattern }, policy), pattern);
  }
});

test("#sandbox-glob-pattern the policy refuses each short pattern that takes fs.globSync out of the folder", () => {
  // Every word of up to two characters from the alphabet, of up to four from
  // its first eight, and of up to five from the brace characters, before
  // `/Other/*` and before the absolute path of `Other`. Runs to four
  // characters from the whole alphabet found `{,\}`, and a review found
  // `.{},.}` at five (2026-11-14).
  const ALPHABET = [".", "[", "]", "{", "}", ",", "\\", "x", "*", "/", "!", "-", "+", "(", ")", "?"];
  const words = (alphabet: string[], n: number): string[] =>
    n === 0 ? [""] : words(alphabet, n - 1).flatMap((w) => alphabet.map((c) => w + c));
  const prefixes = [1, 2].flatMap((n) => words(ALPHABET, n))
    .concat([3, 4].flatMap((n) => words(ALPHABET.slice(0, 8), n)))
    .concat(words([".", "{", "}", ",", "\\", "x"], 5));
  let escapes = 0;
  for (const prefix of prefixes) {
    for (const pattern of [`${prefix}/Other/*`, `${prefix}${path.join(home, "Other")}/*`]) {
      let matches: string[];
      try {
        matches = fs.globSync(pattern, { cwd: notes });
      } catch {
        continue; // not a pattern to globSync
      }
      const outside = matches.some((m) => !path.resolve(notes, m).startsWith(notes + path.sep));
      if (!outside) continue;
      escapes++;
      assert.equal(toolDecision("Glob", { path: notes, pattern }, policy).behavior, "deny", pattern);
    }
  }
  assert.ok(escapes > 0, "no pattern left the folder, so the test checks nothing");
});

test("#codex-files Glob lists a note whose name holds a backslash and `..`", () => {
  // On macOS and Linux a backslash is a character of the name, not a separator.
  const odd = path.join(notes, "a\\..\\odd.md");
  fs.writeFileSync(odd, "odd\n");
  try {
    assert.ok(fileTool("Glob", { path: notes, pattern: "*odd.md" }, policy).text.split("\n").includes(odd));
  } finally {
    fs.rmSync(odd);
  }
});

test("#codex-files Read follows a symlink that stays in a readable folder", () => {
  const alias = path.join(notes, "alias.md");
  fs.symlinkSync(path.join(notes, "a.md"), alias);
  try {
    assert.match(fileTool("Read", { file_path: alias }, policy).text, /alpha/);
  } finally {
    fs.rmSync(alias);
  }
});

test("#codex-files Read of a pipe gives an error and does not wait", { skip: process.platform === "win32" }, () => {
  const fifo = path.join(notes, "pipe");
  assert.equal(spawnSync("mkfifo", [fifo]).status, 0);
  try {
    assert.equal(fileTool("Read", { file_path: fifo }, policy).isError, true);
  } finally {
    fs.rmSync(fifo);
  }
});

// Two readable folders, with `A/k -> B/sub`: `A/k/..` is `B` to the kernel and
// `A` to a lexical join. A Grep there must not open `A/n.txt`, a symlink to an
// unlisted file, as if it were `B/n.txt` (code review 2026-11-14).
test("#codex-files Grep reads no file through a `..` after a symlink", () => {
  const a = path.join(home, "A");
  const b = path.join(home, "B");
  fs.mkdirSync(a);
  fs.mkdirSync(path.join(b, "sub"), { recursive: true });
  fs.writeFileSync(path.join(b, "n.txt"), "harmless\n");
  fs.symlinkSync(path.join(b, "sub"), path.join(a, "k"));
  fs.symlinkSync(path.join(home, "Other", "c.md"), path.join(a, "n.txt"));
  const two = { ...policy, readableFolders: [a, b] };
  for (const output_mode of ["content", "files_with_matches"]) {
    const r = fileTool("Grep", { path: `${path.join(a, "k")}/..`, pattern: "PRIVATE|harmless", output_mode }, two);
    assert.ok(!r.text.includes(SECRET), r.text);
    assert.ok(!r.text.includes(path.join(a, "n.txt")), r.text);
    assert.ok(r.text.includes(path.join(b, "n.txt")), r.text);
  }
});

test("#codex-files Grep finds files, lines and counts in a readable folder", () => {
  const files = fileTool("Grep", { path: notes, pattern: "beta" }, policy);
  assert.equal(files.isError, undefined, files.text);
  assert.deepEqual(files.text.split("\n"), [path.join(notes, "a.md"), path.join(notes, "sub", "b.md")]);
  assert.equal(
    fileTool("Grep", { path: notes, pattern: "beta", output_mode: "content", glob: "a.md" }, policy).text,
    `${path.join(notes, "a.md")}:2:beta`
  );
  assert.equal(
    fileTool("Grep", { path: notes, pattern: "beta", output_mode: "count", glob: "sub/*.md" }, policy).text,
    `${path.join(notes, "sub", "b.md")}:1`
  );
  assert.equal(fileTool("Grep", { path: notes, pattern: "gamma" }, policy).text, "No files found");
  assert.equal(fileTool("Grep", { path: notes, pattern: "gamma", "-i": true }, policy).text, path.join(notes, "a.md"));
  assert.equal(fileTool("Grep", { path: path.join(notes, "a.md"), pattern: "alpha" }, policy).text, path.join(notes, "a.md"));
});

test("#codex-files Grep does not follow a symlink out of a readable folder", () => {
  assert.equal(fileTool("Grep", { path: notes, pattern: "PRIVATE" }, policy).text, "No files found");
});

test("#codex-files Grep refuses a path at or above a store, or outside the readable folders", () => {
  for (const input of [
    { path: home, pattern: "PRIVATE" },
    { path: path.join(home, ".ssh"), pattern: "PRIVATE" },
    { path: path.join(home, "Other"), pattern: "PRIVATE" },
    { path: path.join(notes, "link"), pattern: "PRIVATE" },
    { path: notes, pattern: "PRIVATE", glob: "../**" },
    { pattern: "PRIVATE" },
  ]) {
    assertRefused(fileTool("Grep", input, policy), JSON.stringify(input));
  }
  assert.match(fileTool("Grep", { path: notes, pattern: "(" }, policy).text, /regular expression/);
  assert.equal(fileTool("Grep", { path: notes }, policy).isError, true);
});

test("#codex-files a tool other than Read, Grep and Glob is refused", () => {
  assert.equal(fileTool("Write", { file_path: path.join(notes, "a.md") }, policy).isError, true);
});

test("#codex-files the folder list is the file's list of strings, and none when the file is unreadable", () => {
  const file = path.join(home, "folders.json");
  assert.deepEqual(readFolderList(file), []);
  fs.writeFileSync(file, "not json");
  assert.deepEqual(readFolderList(file), []);
  fs.writeFileSync(file, JSON.stringify({ folders: [notes] }));
  assert.deepEqual(readFolderList(file), []);
  fs.writeFileSync(file, JSON.stringify([notes, 3, "~/Other"]));
  assert.deepEqual(readFolderList(file), [notes, "~/Other"]);
});

test("#codex-files the connector answers MCP requests with the three read-only tools", () => {
  const ctx = { home, cwd: home, folders: () => [notes] };
  const init = mcpReply({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } }, ctx);
  assert.deepEqual(init, {
    jsonrpc: "2.0", id: 1,
    result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "advisor", version: "1" } },
  });
  const list = mcpReply({ jsonrpc: "2.0", id: 2, method: "tools/list" }, ctx) as { result: { tools: typeof FILE_TOOLS } };
  assert.deepEqual(list.result.tools.map((t) => t.name), ["Read", "Grep", "Glob"]);
  assert.ok(list.result.tools.every((t) => t.annotations.readOnlyHint === true));
  const read = (file: string) => mcpReply(
    { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "Read", arguments: { file_path: file } } }, ctx
  ) as { result: { content: { text: string }[]; isError?: boolean } };
  assert.match(read(path.join(notes, "a.md")).result.content[0].text, /alpha/);
  assert.equal(read(path.join(home, ".ssh", "id_test")).result.isError, true);
  assert.deepEqual(mcpReply({ jsonrpc: "2.0", id: 4, method: "ping" }, ctx), { jsonrpc: "2.0", id: 4, result: {} });
  assert.equal((mcpReply({ jsonrpc: "2.0", id: 5, method: "resources/list" }, ctx) as { error: { code: number } }).error.code, -32601);
  assert.equal(mcpReply({ jsonrpc: "2.0", method: "notifications/initialized" }, ctx), undefined);
  // A tool that fails is an error result, not a dead server.
  const failing = { ...ctx, folders: (): string[] => { throw new Error("disk gone"); } };
  const failed = mcpReply(
    { jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "Read", arguments: { file_path: path.join(notes, "a.md") } } },
    failing
  ) as { result: { content: { text: string }[]; isError?: boolean } };
  assert.equal(failed.result.isError, true);
  assert.match(failed.result.content[0].text, /disk gone/);
});

test("#codex-files the connector process reads the folder list at each call", async () => {
  const folders = path.join(home, "folders.json");
  fs.writeFileSync(folders, JSON.stringify([notes]));
  const script = fileURLToPath(new URL("./localFilesMcp.js", import.meta.url));
  const child = spawn(process.execPath, [script, home, folders], { stdio: ["pipe", "pipe", "inherit"] });
  const replies = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const call = async (id: number, method: string, params: object): Promise<{ result: { content?: { text: string }[]; isError?: boolean } }> => {
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return JSON.parse((await replies.next()).value as string);
  };
  try {
    await call(1, "initialize", { protocolVersion: "2025-06-18" });
    const note = { name: "Read", arguments: { file_path: path.join(notes, "a.md") } };
    assert.match((await call(2, "tools/call", note)).result.content?.[0].text ?? "", /alpha/);
    const key = await call(3, "tools/call", { name: "Read", arguments: { file_path: path.join(home, ".ssh", "id_test") } });
    assert.equal(key.result.isError, true);
    fs.writeFileSync(folders, JSON.stringify([]));
    assert.equal((await call(4, "tools/call", note)).result.isError, true);
  } finally {
    child.kill();
  }
});
