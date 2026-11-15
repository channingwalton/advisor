import { test, after, before } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";
import { FILE_TOOLS, fileTool, globFiles, mcpReply, readFolderList, type FileToolResult } from "./localFiles.js";
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

/// The paths that `globFiles` lists.
function globbed(root: string, pattern: string, fold?: boolean): string[] {
  return globFiles(root, pattern, fold).map((f) => f.file);
}

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

/// Short patterns that try to leave `notes` for `Other`, and those that take
/// `fs.globSync` out of the folder. Every word of up to two characters from
/// the alphabet, of up to four from its first eight, and of up to five from
/// the brace characters, before `/Other/*` and before the absolute path of
/// `Other`. Runs to four characters from the whole alphabet found `{,\}`, and
/// a review found `.{},.}` at five (2026-11-14).
function shortPatterns(): { pattern: string; escapes: boolean }[] {
  const ALPHABET = [".", "[", "]", "{", "}", ",", "\\", "x", "*", "/", "!", "-", "+", "(", ")", "?"];
  const words = (alphabet: string[], n: number): string[] =>
    n === 0 ? [""] : words(alphabet, n - 1).flatMap((w) => alphabet.map((c) => w + c));
  const prefixes = [1, 2].flatMap((n) => words(ALPHABET, n))
    .concat([3, 4].flatMap((n) => words(ALPHABET.slice(0, 8), n)))
    .concat(words([".", "{", "}", ",", "\\", "x"], 5));
  return prefixes.flatMap((prefix) =>
    [`${prefix}/Other/*`, `${prefix}${path.join(home, "Other")}/*`].flatMap((pattern) => {
      let matches: string[];
      try {
        matches = fs.globSync(pattern, { cwd: notes });
      } catch {
        return []; // not a pattern to globSync
      }
      return [{ pattern, escapes: matches.some((m) => !path.resolve(notes, m).startsWith(notes + path.sep)) }];
    })
  );
}

test("#sandbox-glob-pattern the policy refuses each short pattern that takes fs.globSync out of the folder", () => {
  const escaping = shortPatterns().filter((p) => p.escapes);
  assert.ok(escaping.length > 0, "no pattern left the folder, so the test checks nothing");
  for (const { pattern } of escaping) {
    assert.equal(toolDecision("Glob", { path: notes, pattern }, policy).behavior, "deny", pattern);
  }
});

test("#codex-files Glob walks only its folder, whatever the pattern", () => {
  // Without the policy: the patterns that take `fs.globSync` out of the
  // folder, and the review's spellings, list no file outside it.
  const patterns = shortPatterns().filter((p) => p.escapes).map((p) => p.pattern).concat([
    "../Other/*", "[.][.]/Other/*", "{.,x}./Other/*", ".{},.}/Other/*", `{x,\\}${home}/Other/*`, `\\${home}/Other/*`,
    `${home}/Other/*`, "**/../../Other/*",
  ]);
  for (const pattern of patterns) {
    const outside = globbed(notes, pattern).filter((f) => !f.startsWith(notes + path.sep));
    assert.deepEqual(outside, [], pattern);
  }
  // It lists hidden files when the pattern names them, as `fs.globSync` does.
  fs.mkdirSync(path.join(notes, ".obsidian"));
  fs.writeFileSync(path.join(notes, ".obsidian", "app.json"), "{}");
  try {
    assert.deepEqual(globbed(notes, ".obsidian/*"), [path.join(notes, ".obsidian", "app.json")]);
    assert.ok(!globbed(notes, "**/*").some((f) => f.includes(".obsidian")));
  } finally {
    fs.rmSync(path.join(notes, ".obsidian"), { recursive: true });
  }
});

test("#codex-files Glob takes a pattern that starts with `./`, and on macOS a name in another case", () => {
  // As `fs.globSync` did (code review 2026-11-15).
  const a = path.join(notes, "a.md");
  const b = path.join(notes, "sub", "b.md");
  assert.deepEqual(globbed(notes, "./*.md"), [a]);
  assert.deepEqual(globbed(notes, "./sub/b.md"), [b]);
  assert.deepEqual(globbed(notes, "sub/./b.md"), [b]);
  assert.deepEqual(globbed(notes, "*/."), []); // folders, which Glob does not list
  // `path.matchesGlob` and `fs.globSync` read a `\` as a `/` (code review 2026-11-15).
  assert.deepEqual(globbed(notes, "sub\\*.md"), [b]);
  assert.deepEqual(globbed(notes, ".\\*.md"), [a]);
  // Empty names, and `./` at the start of a brace alternative (code review and
  // comparison with `fs.globSync`, 2026-11-15).
  for (const pattern of [".//*.md", "./\\*.md", ".\\/*.md", ".\\\\*.md", "{./a,x}.md", "{.,x}/a.md"]) {
    assert.deepEqual(globbed(notes, pattern), [a], pattern);
  }
  assert.deepEqual(globbed(notes, "{./sub,x}/*.md"), [b]);
  assert.deepEqual(globbed(notes, "sub//b.md"), [b]);
  // `fs.globSync` reads `[.]` as `.` (code review 2026-11-15).
  for (const pattern of ["[.]/a.md", "[.]//*.md", "{[.],x}/a.md"]) assert.deepEqual(globbed(notes, pattern), [a], pattern);
  for (const pattern of ["sub/[.]/b.md", "{sub/[.],x}/b.md", "{sub/.,x}/b.md"]) assert.deepEqual(globbed(notes, pattern), [b], pattern);
  if (process.platform === "darwin") {
    assert.deepEqual(globbed(notes, "A.md"), [a]);
    assert.deepEqual(globbed(notes, "SUB/*.md"), [b]);
  }
  // Grep's `glob` drops `.` segments too, and then matches a name when it
  // holds no `/`. In letter case it is exact, as ripgrep's is.
  const grep = (glob: string) => fileTool("Grep", { path: notes, pattern: "beta", glob }, policy).text.split("\n").sort();
  assert.deepEqual(grep("./sub/*.md"), [b]);
  assert.deepEqual(grep("sub\\*.md"), [b]);
  assert.deepEqual(grep("./*.md"), grep("*.md"));
  assert.deepEqual(grep(".//sub/*.md"), [b]);
  assert.deepEqual(grep("{./sub,x}/*.md"), [b]);
  // The file name, when no brace alternative has a `/`, as for ripgrep (code
  // review 2026-11-15).
  assert.deepEqual(grep("./b.md"), [b]);
  assert.deepEqual(grep("{./b,x}.md"), [b]);
  assert.deepEqual(grep("{./a,b}.md"), [a, b]);
  assert.deepEqual(grep("{a,sub/b}.md"), [a, b]);
  assert.deepEqual(grep("{b,sub/x}.md"), ["No files found"]);
  assert.deepEqual(grep("*.md"), [a, b]);
  assert.deepEqual(grep("SUB/*.md"), ["No files found"]);
});

test("#codex-files Glob opens only the folders that the pattern can match in", () => {
  // A hidden folder only for a pattern that can match a hidden name, and only
  // the folder that a pattern's leading names give (code review 2026-11-15).
  const git = path.join(notes, ".git");
  fs.mkdirSync(path.join(git, "objects"), { recursive: true });
  const opened: string[] = [];
  const readdir = fs.readdirSync;
  fs.readdirSync = ((dir: fs.PathLike, options?: unknown) => {
    opened.push(String(dir));
    return (readdir as (d: fs.PathLike, o?: unknown) => unknown)(dir, options);
  }) as typeof fs.readdirSync;
  const opens = (pattern: string): string[] => {
    opened.length = 0;
    globbed(notes, pattern);
    return [...opened];
  };
  try {
    assert.ok(!opens("**/*.md").includes(git));
    assert.ok(!opens("**/*.[mM][dD]").includes(git));
    assert.ok(!opens("**/[0-9]*.md").includes(git));
    assert.ok(opens("?(x).git/*").includes(git));
    assert.ok(opens("@(x|.git)/*").includes(git));
    assert.ok(opens(".git/*").includes(git));
    assert.ok(opens("**/[.]*").includes(git));
    assert.ok(opens(".git\\*").includes(git));
    // A brace that leaves a dot first, or makes a `**` (code review 2026-11-15).
    assert.ok(opens("{x,}.git/*").includes(git));
    assert.ok(opens("{*,}*/b.md").includes(path.join(notes, "sub")));
    // A leading folder is found in its folder's listing. One that is missing
    // or a symlink: nothing can match.
    assert.deepEqual(opens("missing/**/*.md"), [notes]);
    assert.deepEqual(opens("link/*"), [notes]);
    assert.deepEqual(opens("sub/*.md"), [notes, path.join(notes, "sub")]);
    assert.deepEqual(opens("sub\\*.md"), [notes, path.join(notes, "sub")]);
    // No deeper than the pattern can match, without `**`.
    assert.deepEqual(opens("*.md"), [notes]);
    assert.deepEqual(opens("{./a,x}.md"), [notes]);
    assert.ok(opens("**/*.md").includes(path.join(notes, "sub")));
    if (process.platform === "darwin") assert.deepEqual(opens("SUB/*.md"), [notes, path.join(notes, "sub")]);
  } finally {
    fs.readdirSync = readdir;
    fs.rmSync(git, { recursive: true });
  }
});

test("#codex-files Glob finds a leading folder in another letter case on a case-sensitive volume", (t) => {
  // As on a case-sensitive macOS volume, where Glob folds case (code review
  // 2026-11-15). Linux has such a volume; macOS usually does not.
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-case-")));
  try {
    fs.mkdirSync(path.join(dir, "sub"));
    fs.writeFileSync(path.join(dir, "sub", "b.md"), "");
    if (fs.existsSync(path.join(dir, "SUB"))) {
      t.skip("this volume ignores letter case");
      return;
    }
    const b = path.join(dir, "sub", "b.md");
    assert.deepEqual(globbed(dir, "SUB/*.md", true), [b]);
    assert.deepEqual(globbed(dir, "[S]UB/*.md", true), [b]);
    assert.deepEqual(globbed(dir, "sub/[B].md", true), [b]);
    assert.deepEqual(globbed(dir, "sub/[B-B].md", true), [b]);
    assert.deepEqual(globbed(dir, "SUB/*.md", false), []);
    // Two folders that match give the folder that holds them.
    fs.mkdirSync(path.join(dir, "Sub"));
    fs.writeFileSync(path.join(dir, "Sub", "c.md"), "");
    assert.deepEqual(globbed(dir, "SUB/*.md", true).sort(), [path.join(dir, "Sub", "c.md"), b].sort());
    assert.deepEqual(globbed(dir, "sub/*.md", false), [b]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("#codex-files Glob and Grep list nothing from a folder that is swapped for a symlink during the walk", () => {
  // Another process can swap a folder between the walk's steps: before its
  // listing, before Glob's stat of a file in it, or before Grep's read. The
  // old Glob judged each match for this (code review 2026-11-15).
  const sub = path.join(notes, "sub");
  const b = path.join(sub, "b.md");
  const outside = fs.mkdtempSync(path.join(home, "outside-"));
  fs.writeFileSync(path.join(outside, "b.md"), `${SECRET}\n`);
  // `run`, with `sub` swapped for a symlink to `outside` when `method` is
  // first called on `at`.
  const swapped = <T>(method: "readdirSync" | "lstatSync" | "openSync", at: string, run: () => T): T => {
    const target = fs as unknown as Record<string, (...args: unknown[]) => unknown>;
    const original = target[method];
    let done = false;
    target[method] = (...args: unknown[]) => {
      if (!done && String(args[0]) === at) {
        done = true;
        fs.renameSync(sub, `${sub}-kept`);
        fs.symlinkSync(outside, sub);
      }
      return original.apply(fs, args);
    };
    try {
      return run();
    } finally {
      target[method] = original;
      if (done) {
        fs.unlinkSync(sub);
        fs.renameSync(`${sub}-kept`, sub);
      }
    }
  };
  try {
    assert.deepEqual(swapped("readdirSync", sub, () => globbed(notes, "sub/*.md")), []);
    assert.deepEqual(swapped("readdirSync", sub, () => globbed(notes, "**/*.md")), [path.join(notes, "a.md")]);
    assert.deepEqual(swapped("lstatSync", b, () => globbed(notes, "sub/*.md")), []);
    for (const [method, at] of [["readdirSync", sub], ["openSync", b]] as const) {
      const r = swapped(method, at, () => fileTool("Grep", { path: notes, pattern: "PRIVATE", output_mode: "content" }, policy));
      assert.equal(r.text, "No matches found", method);
    }
  } finally {
    fs.rmSync(outside, { recursive: true });
  }
  assert.ok(fs.existsSync(b));
});

test("#codex-files Glob finds a name in another Unicode form when it folds case", () => {
  // A name copied from HFS+ is often in NFD, and a typed one is in NFC; a
  // macOS volume finds either (code review 2026-11-15).
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-nfc-")));
  try {
    const nfd = "cafe\u0301";
    fs.mkdirSync(path.join(dir, nfd));
    fs.writeFileSync(path.join(dir, nfd, `${nfd}.md`), "");
    const [name] = fs.readdirSync(dir);
    const file = path.join(dir, name, fs.readdirSync(path.join(dir, name))[0]);
    for (const pattern of ["caf\u00e9/*.md", "caf\u00e9/caf\u00e9.md", "*/caf\u00e9.md", "CAFE\u0301/*.md", "caf[\u00e9]/*.md"]) {
      assert.deepEqual(globbed(dir, pattern, true), [file], pattern);
    }
    assert.deepEqual(globbed(dir, "caf\u00e9/*.md", false), name === "caf\u00e9" ? [file] : []);
    // Matched only in the folded form, a negation leaves the name out in either
    // form, and a class keeps its range (code review 2026-11-15).
    assert.deepEqual(globbed(dir, "*/!(caf\u00e9).md", true), []);
    assert.deepEqual(globbed(dir, "*/[Z-c]af\u00e9.md", true), [file]);
    // `path.matchesGlob` reads a class of one character as a literal.
    assert.deepEqual(globbed(dir, "*/[C]AF\u00c9.md", true), [file]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("#codex-files Glob of a file gives an error", () => {
  const r = fileTool("Glob", { path: path.join(notes, "a.md"), pattern: "*" }, policy);
  assert.equal(r.isError, true, r.text);
  assert.match(r.text, /not a folder/);
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

test("#codex-files Read follows a symlink that stays in a readable folder; Glob and Grep do not list it", () => {
  // Glob and Grep follow no symlink, as the Claude CLI's search does not.
  const alias = path.join(notes, "alias.md");
  fs.symlinkSync(path.join(notes, "a.md"), alias);
  try {
    assert.match(fileTool("Read", { file_path: alias }, policy).text, /alpha/);
    assert.ok(!fileTool("Glob", { path: notes, pattern: "*.md" }, policy).text.includes("alias"));
    assert.ok(!fileTool("Grep", { path: notes, pattern: "alpha" }, policy).text.includes("alias"));
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
