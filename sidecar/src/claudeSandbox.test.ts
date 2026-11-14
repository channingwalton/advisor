import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  claudeSandboxPolicy, claudeSandboxProfile, claudeWriteFolders, spawnClaudeSandboxed, type ClaudeReads,
} from "./claudeSandbox.js";
import { realpathOrSelf, writableTemps } from "./seatbelt.js";

// The Claude CLI and its stdio connectors under a Seatbelt profile
// (GHSA-6xc8-f55f-jxqr, fault 2): in the home folder they read only the
// readable folders and what the CLI needs to run.

/// Seatbelt is macOS-only; CI runs the sidecar on Linux.
const darwin = { skip: process.platform !== "darwin" ? "requires macOS Seatbelt" : false };

/// A throwaway home: a readable folder, an unlisted folder, a store, the CLI's
/// state, a keychain, the CLI folder and the working folder.
function fakeHome(prefix = "advisor-claude-sb-"): { home: string; reads: (keychain: boolean, folders?: string[]) => ClaudeReads } {
  const home = realpathOrSelf(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  const files: Record<string, string> = {
    "Documents/notes.txt": "ordinary notes",
    "Private/plan.txt": "private plan",
    ".ssh/id_rsa": "PRIVATE KEY",
    ".claude/settings.json": "{}",
    ".claude.json": "{}",
    "Library/Keychains/login.keychain-db": "keychain",
    "Library/Keychains/other.keychain-db": "other keychain",
    "Library/Keychains/.fl34AC2A0A": "lock",
    "cli/claude": "binary",
    "Library/Application Support/Advisor/agent-cwd/x": "cwd file",
  };
  for (const [file, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(home, file)), { recursive: true });
    fs.writeFileSync(path.join(home, file), text);
  }
  return {
    home,
    reads: (keychain, folders = [path.join(home, "Documents")]) => ({
      folders, keychain, cliRoot: path.join(home, "cli"),
      cwd: path.join(home, "Library", "Application Support", "Advisor", "agent-cwd"),
    }),
  };
}

/// Run `command` under `profile` through the SDK spawn hook, and return its
/// exit code and its whole output: the output can end after the exit, and a
/// check that the output lacks a secret must not pass on a lost output (code
/// review 2026-11-14).
async function sandboxed(profile: string, command: string, args: string[]): Promise<{ code: number | null; out: string }> {
  const signal = new AbortController().signal;
  const child = spawnClaudeSandboxed({ command, args, env: { PATH: "/usr/bin:/bin" }, signal }, profile, () => {});
  child.stdin.end();
  let out = "";
  child.stdout.on("data", (d: Buffer) => (out += d.toString()));
  const ended = new Promise<void>((resolve) => child.stdout.once("end", () => resolve()));
  const code = await new Promise<number | null>((resolve, reject) => {
    child.once("exit", (c) => resolve(c));
    child.once("error", reject);
  });
  await ended;
  return { code, out };
}

// The CLI's stderr reaches the session's log, as the SDK's own spawn sends it
// there: a CLI that cannot start, or a profile that does not compile, would
// otherwise show only as "exited with code N" (code review 2026-11-11).
test("#claude-seatbelt the sandboxed spawn passes the CLI's stderr on", darwin, async () => {
  const lines: string[] = [];
  const signal = new AbortController().signal;
  const child = spawnClaudeSandboxed(
    { command: "/bin/sh", args: ["-c", "echo started >&2"], env: { PATH: "/usr/bin:/bin" }, signal },
    "(version 1)\n(allow default)\n",
    (data) => lines.push(data)
  );
  child.stdin.end();
  await new Promise((resolve) => child.once("exit", resolve));
  assert.match(lines.join(""), /started/);
  const broken: string[] = [];
  const bad = spawnClaudeSandboxed(
    { command: "/bin/echo", args: [], env: { PATH: "/usr/bin:/bin" }, signal }, "(version 1)\n(bogus", (d) => broken.push(d)
  );
  bad.stdin.end();
  const code = await new Promise((resolve) => bad.once("exit", resolve));
  assert.notEqual(code, 0);
  assert.match(broken.join(""), /sandbox-exec/);
});

test("#claude-seatbelt the policy allows the CLI's state, and the login keychain only for a subscription login", () => {
  const { home, reads } = fakeHome();
  const login = claudeSandboxPolicy(home, reads(true), [path.join(home, "tmp")]);
  const keyed = claudeSandboxPolicy(home, reads(false), [path.join(home, "tmp")]);
  for (const p of [".claude", ".claude.json", "Documents", "cli", "Library/Application Support/Advisor/agent-cwd"]) {
    assert.ok(login.readRoots.includes(path.join(home, p)), p);
  }
  const keychains = path.join(home, "Library", "Keychains");
  const loginKeychain = path.join(keychains, "login.keychain-db");
  assert.ok(login.readRoots.includes(loginKeychain));
  assert.ok(!login.readRoots.includes(keychains), "the login keychain file, not its folder");
  assert.ok(login.readMetadata.includes(keychains));
  assert.ok(!keyed.readRoots.includes(loginKeychain));
  assert.ok(keyed.readDenials.includes(keychains), "an API-key login keeps the keychain refused");
  // The state is not refused at the end, or the CLI could not read it.
  assert.ok(!login.readDenials.includes(path.join(home, ".claude")));
  // Writes are confined to the temp folders, `/dev`, the CLI's transcripts
  // and its connectors' logs, and in subscription mode the login keychain
  // (decided 2026-11-14).
  const [transcripts, logs] = claudeWriteFolders(home, reads(false).cwd);
  const slug = path.join(home, "Library/Application Support/Advisor/agent-cwd").replace(/[^a-zA-Z0-9]/g, "-");
  assert.equal(transcripts, path.join(home, ".claude", "projects", slug));
  assert.equal(logs, path.join(home, "Library", "Caches", "claude-cli-nodejs", slug));
  for (const policy of [login, keyed]) {
    assert.equal(policy.confineWrites, true);
    for (const p of [path.join(home, "tmp"), "/dev", transcripts, logs]) assert.ok(policy.writableRoots.includes(p), p);
    assert.ok(!policy.writableRoots.includes(path.join(home, ".claude")) && !policy.writableRoots.includes(home));
  }
  assert.ok(login.writableRoots.includes(loginKeychain));
  assert.ok(login.writePatterns.length > 0, "the keychain's temp and lock files");
  assert.ok(!keyed.writableRoots.includes(loginKeychain));
  assert.deepEqual(keyed.writePatterns, []);
  assert.match(claudeSandboxProfile(home, reads(true)), /\(deny appleevent-send\)/);
});

// A `rename` needs a write of its source, so a process that could write the
// home folder could move a store into a readable folder and read it there
// (code review 2026-11-14). Writes are confined, so it cannot.
test("#claude-seatbelt a process writes only the temp folders, the CLI's transcripts and its connectors' logs", darwin, async () => {
  const { home, reads } = fakeHome();
  const tmp = path.join(home, "tmp");
  fs.mkdirSync(tmp);
  const [transcripts, logs] = claudeWriteFolders(home, reads(false).cwd);
  for (const dir of [transcripts, logs]) fs.mkdirSync(dir, { recursive: true });
  const profile = claudeSandboxProfile(home, reads(false), [tmp]);
  const sh = (script: string) => sandboxed(profile, "/bin/sh", ["-c", script]);
  const allowed = await sh(`echo t > "${transcripts}/s.jsonl" && echo l > "${logs}/m.jsonl" && echo x > "${tmp}/x" && echo n > /dev/null`);
  assert.equal(allowed.code, 0);
  assert.equal(fs.readFileSync(path.join(transcripts, "s.jsonl"), "utf8"), "t\n");
  for (const file of ["Documents/new.txt", "Documents/notes.txt", ".claude/settings.json", ".claude.json", "Library/x", "x"]) {
    assert.notEqual((await sh(`echo x > "${path.join(home, file)}"`)).code, 0, file);
  }
  assert.equal(fs.readFileSync(path.join(home, "Documents", "notes.txt"), "utf8"), "ordinary notes");
  const store = await sh(`mv "${home}/.ssh" "${home}/Documents/s"; cat "${home}/Documents/s/id_rsa"`);
  assert.ok(!store.out.includes("PRIVATE KEY"), store.out);
  assert.ok(fs.existsSync(path.join(home, ".ssh", "id_rsa")), "the store stays where it is");
  const folder = await sh(`mv "${home}/Private" "${home}/Documents/P"; cat "${home}/Documents/P/plan.txt"`);
  assert.ok(!folder.out.includes("private plan"), folder.out);
  assert.notEqual((await sh(`mv "${home}/Library" "${home}/Documents/L"`)).code, 0, "a folder above a store stays");
});

// `security` writes a keychain under its lock file (`.fl` and a hash), which it
// must read: without it, the CLI could not save a refreshed login (verified
// 2026-11-11). Each home spelling, with its regex characters escaped.
test("#claude-seatbelt a subscription login can read the login keychain's lock files", darwin, async () => {
  const { home, reads } = fakeHome("advisor claude (sb).home+");
  const keychains = path.join(home, "Library", "Keychains");
  const login = claudeSandboxProfile(home, reads(true), [path.join(home, "tmp")]);
  const lock = await sandboxed(login, "/bin/cat", [path.join(keychains, ".fl34AC2A0A")]);
  assert.equal(lock.code, 0);
  assert.equal(lock.out, "lock");
  const other = await sandboxed(login, "/bin/cat", [path.join(keychains, "other.keychain-db")]);
  assert.notEqual(other.code, 0);
  const keyed = claudeSandboxProfile(home, reads(false), [path.join(home, "tmp")]);
  assert.notEqual((await sandboxed(keyed, "/bin/cat", [path.join(keychains, ".fl34AC2A0A")])).code, 0);
});

// `security` saves a keychain as a temp file beside it, which it renames over
// the keychain, under the lock file. So a subscription login can save a
// refreshed token: without that, the stored login could go stale for every
// client (verified with `security` on a throwaway keychain, 2026-11-14).
test("#claude-seatbelt a subscription login can save the login keychain, and only it", darwin, async () => {
  const { home, reads } = fakeHome("advisor claude (sb).home+");
  const keychains = path.join(home, "Library", "Keychains");
  // As `security` saves: write the temp file, rename it over the keychain
  // without a `stat` of the temp file first (which `mv` makes), and use the
  // lock file.
  const temp = path.join(keychains, "login.keychain-db.sb-1a2b");
  const save = ["-c",
    `echo new > "${temp}" && /usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or die' "${temp}" "${path.join(keychains, "login.keychain-db")}"` +
    ` && echo >> "${path.join(keychains, ".fl34AC2A0A")}"`];
  const keyed = claudeSandboxProfile(home, reads(false), [path.join(home, "tmp")]);
  assert.notEqual((await sandboxed(keyed, "/bin/sh", save)).code, 0, "an API-key login cannot write the keychain");
  const login = claudeSandboxProfile(home, reads(true), [path.join(home, "tmp")]);
  assert.equal((await sandboxed(login, "/bin/sh", save)).code, 0);
  assert.equal(fs.readFileSync(path.join(keychains, "login.keychain-db"), "utf8"), "new\n");
  const other = await sandboxed(login, "/bin/sh", ["-c", `echo x > "${keychains}/other.keychain-db"`]);
  assert.notEqual(other.code, 0);
  assert.equal(fs.readFileSync(path.join(keychains, "other.keychain-db"), "utf8"), "other keychain");
});

// The kernel matches resolved paths, so a temp folder is judged by where it
// leads: a `TMPDIR` in the home folder that leads out of it stays writable,
// and one outside that leads to a store does not (code review 2026-11-14).
test("#claude-seatbelt a temp folder is judged by where its symlinks lead", () => {
  const { home } = fakeHome();
  const outside = realpathOrSelf(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-tmp-out-")));
  try {
    fs.mkdirSync(path.join(home, "tmp"));
    fs.symlinkSync(outside, path.join(home, "tmplink"));
    fs.symlinkSync(path.join(home, "Library"), path.join(outside, "library"));
    fs.symlinkSync(path.join(home, "tmp"), path.join(outside, "tmp"));
    const tmps = [path.join(home, "tmplink"), path.join(outside, "library"), path.join(outside, "tmp")];
    assert.deepEqual(writableTemps(home, tmps), [path.join(home, "tmplink"), path.join(outside, "tmp")]);
  } finally {
    fs.rmSync(outside, { recursive: true, force: true });
  }
});

test("#claude-seatbelt a CLI, working or config folder at or above a store is not opened", () => {
  const { home, reads } = fakeHome();
  const library = path.join(home, "Library");
  const wide = claudeSandboxPolicy(home, { ...reads(false), cliRoot: library, cwd: home, configDir: home }, [library]);
  assert.ok(!wide.readRoots.includes(library) && !wide.readRoots.includes(home), wide.readRoots.join("\n"));
  // Nor written: a process could move a store out of it to `/tmp`, which it
  // can write and read (code review 2026-11-14).
  assert.ok(!wide.writableRoots.includes(library), wide.writableRoots.join("\n"));
  // Nor a temp folder above the home folder, such as `TMPDIR=/Users`, which
  // holds every store in it (code review 2026-11-14).
  const above = claudeSandboxPolicy(home, reads(false), [path.dirname(home), "/", path.join(home, "tmp")]);
  const own = ["/dev", ...claudeWriteFolders(home, reads(false).cwd)];
  assert.deepEqual(above.writableRoots.filter((r) => !own.includes(r)), [path.join(home, "tmp")]);
  const config = path.join(home, ".config", "claude");
  assert.ok(claudeSandboxPolicy(home, { ...reads(false), configDir: config }).readRoots.includes(config));
  // A `CLAUDE_CONFIG_DIR` that is not absolute, such as a `~/…` that no shell
  // expanded, names no folder to create or allow: the session would create it
  // under its own working folder (code review 2026-11-14).
  assert.deepEqual(claudeWriteFolders(home, reads(false).cwd, "~/.claude-work"), []);
  assert.equal(claudeWriteFolders(home, reads(false).cwd, config)[0], path.join(config, "projects", path.basename(claudeWriteFolders(home, reads(false).cwd)[0])));
});

test("#claude-seatbelt a process started through the spawn hook reads only what the profile allows", darwin, async () => {
  const { home, reads } = fakeHome();
  const profile = claudeSandboxProfile(home, reads(false), [path.join(home, "tmp")]);
  const cat = (file: string) => sandboxed(profile, "/bin/cat", [path.join(home, file)]);
  for (const [file, text] of [
    ["Documents/notes.txt", "ordinary notes"], [".claude/settings.json", "{}"], [".claude.json", "{}"],
    ["cli/claude", "binary"], ["Library/Application Support/Advisor/agent-cwd/x", "cwd file"],
  ]) {
    const r = await cat(file);
    assert.equal(r.code, 0, file);
    assert.equal(r.out, text, file);
  }
  for (const [file, text] of [
    ["Private/plan.txt", "private plan"], [".ssh/id_rsa", "PRIVATE KEY"], ["Library/Keychains/login.keychain-db", "keychain"],
  ]) {
    const r = await cat(file);
    assert.notEqual(r.code, 0, file);
    assert.ok(!r.out.includes(text), file);
  }
  // With a subscription login, the login keychain is readable, and only it
  // (decided 2026-11-11).
  const login = claudeSandboxProfile(home, reads(true), [path.join(home, "tmp")]);
  const keychains = path.join(home, "Library", "Keychains");
  const keychain = await sandboxed(login, "/bin/cat", [path.join(keychains, "login.keychain-db")]);
  assert.equal(keychain.out, "keychain");
  const other = await sandboxed(login, "/bin/cat", [path.join(keychains, "other.keychain-db")]);
  assert.notEqual(other.code, 0);
  assert.ok(!other.out.includes("other keychain"));
  const list = await sandboxed(login, "/bin/ls", [keychains]);
  assert.notEqual(list.code, 0, "the keychain folder cannot be listed");
  // The CLI's children inherit the profile: a connector cannot read past it.
  const child = await sandboxed(profile, "/bin/sh", ["-c", `/bin/cat ${path.join(home, "Private", "plan.txt")}`]);
  assert.notEqual(child.code, 0);
  assert.ok(!child.out.includes("private plan"));
});
