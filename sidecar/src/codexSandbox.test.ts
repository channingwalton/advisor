import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { deniedPaths } from "./agent.js";
import { codexConstructorOptions } from "./codex.js";
import {
  codexWrapperScript,
  installCodexSandbox,
  realpathOrSelf,
  sandboxPolicy,
  sandboxReadDenials,
  seatbeltProfile,
} from "./codexSandbox.js";

/// Seatbelt is macOS-only; CI runs the sidecar on Linux.
const darwin = { skip: process.platform !== "darwin" ? "requires macOS Seatbelt" : false };

/// A throwaway home laid out like the real one. It lives under the system temp
/// dir, but the profile's writable root is a *subdirectory* of it, so the rest
/// of the fake home is genuinely outside every allowed root — otherwise the
/// blanket temp allowance would mask the write denials under test.
function fakeHome(opts: { symlinkDotfiles?: boolean } = {}): {
  home: string;
  tmp: string;
  profile: string;
} {
  const home = realpathOrSelf(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-sb-")));
  for (const d of ["Documents", "tmp"]) fs.mkdirSync(path.join(home, d), { recursive: true });

  // `.ssh` and `.codex` either sit directly in home or, as on a dotfiles-managed
  // machine, are symlinks into `~/dotfiles`. Seatbelt matches resolved paths, so
  // the second layout must be enforced identically — it is not, unless the
  // policy resolves them.
  const root = opts.symlinkDotfiles ? path.join(home, "dotfiles") : home;
  for (const d of [".ssh", ".aws", ".codex"]) {
    fs.mkdirSync(path.join(root, d), { recursive: true });
    if (opts.symlinkDotfiles) fs.symlinkSync(path.join(root, d), path.join(home, d));
  }
  fs.writeFileSync(path.join(root, ".ssh", "id_rsa"), "PRIVATE KEY");
  fs.writeFileSync(path.join(root, ".codex", "auth.json"), "provider token");
  fs.writeFileSync(path.join(home, "Documents", "notes.txt"), "hello");

  const tmp = path.join(home, "tmp");
  const profile = path.join(tmp, "advisor.sb");
  const policy = sandboxPolicy(home, [tmp]);
  fs.writeFileSync(profile, seatbeltProfile(policy.readDenials, policy.writableRoots));
  return { home, tmp, profile };
}

function sandboxed(profile: string, argv: string[]): { code: number; out: string; err: string } {
  const r = spawnSync("/usr/bin/sandbox-exec", ["-f", profile, ...argv], { encoding: "utf8" });
  return { code: r.status ?? -1, out: r.stdout ?? "", err: r.stderr ?? "" };
}

test("the OS sandbox denies every path the Claude backend denies, bar Codex's own state", () => {
  const home = "/home/u";
  const denied = sandboxReadDenials(home);
  for (const p of deniedPaths(home)) {
    const providerState = p === "/home/u/.codex" || p === "/home/u/.codex-global-state.json";
    assert.equal(denied.includes(p), !providerState, p);
  }
  // Parity is the point: one denylist, both backends.
  assert.equal(denied.length, deniedPaths(home).length - 2);
});

test("the profile denies the read paths and confines writes to the writable roots", () => {
  const profile = seatbeltProfile(["/home/u/.ssh"], ["/home/u/.codex"]);
  assert.match(profile, /^\(version 1\)/);
  assert.match(profile, /\(deny file-read\* \(subpath "\/home\/u\/\.ssh"\)\)/);
  assert.match(profile, /\(deny file-write\*\)/);
  assert.match(profile, /\(allow file-write\* \(subpath "\/home\/u\/\.codex"\)\)/);
  // The allow must follow the deny: Seatbelt takes the last matching rule.
  assert.ok(profile.indexOf("(deny file-write*)") < profile.indexOf("(allow file-write*"));
});

test("profile paths are escaped so a quote cannot terminate the s-expression", () => {
  const profile = seatbeltProfile(['/home/u/a"b\\c'], []);
  assert.match(profile, /\(subpath "\/home\/u\/a\\"b\\\\c"\)/);
});

test("codexConstructorOptions routes the CLI through the sandbox wrapper", () => {
  assert.deepEqual(codexConstructorOptions({}, "/w/codex"), { codexPathOverride: "/w/codex" });
  assert.deepEqual(codexConstructorOptions({ OPENAI_API_KEY: "sk-x" }, "/w/codex"), {
    apiKey: "sk-x",
    codexPathOverride: "/w/codex",
  });
});

test("a sandboxed process cannot read a private key", darwin, () => {
  const { home, profile } = fakeHome();
  const r = sandboxed(profile, ["/bin/cat", path.join(home, ".ssh", "id_rsa")]);
  assert.notEqual(r.code, 0);
  assert.doesNotMatch(r.out, /PRIVATE KEY/);
  assert.match(r.err, /Operation not permitted/);
});

test("a sandboxed process cannot reach a denied path through a symlink", darwin, () => {
  const { home, profile } = fakeHome();
  fs.symlinkSync(path.join(home, ".ssh"), path.join(home, "Documents", "link"));
  const r = sandboxed(profile, ["/bin/cat", path.join(home, "Documents", "link", "id_rsa")]);
  assert.notEqual(r.code, 0);
  assert.doesNotMatch(r.out, /PRIVATE KEY/);
});

test("a sandboxed process can still read ordinary files", darwin, () => {
  const { home, profile } = fakeHome();
  const r = sandboxed(profile, ["/bin/cat", path.join(home, "Documents", "notes.txt")]);
  assert.equal(r.code, 0);
  assert.match(r.out, /hello/);
});

test("a sandboxed process can still read and write Codex's own state", darwin, () => {
  // Login must survive the sandbox, or the backend is simply broken.
  const { home, profile } = fakeHome();
  const read = sandboxed(profile, ["/bin/cat", path.join(home, ".codex", "auth.json")]);
  assert.equal(read.code, 0);
  assert.match(read.out, /provider token/);
  const session = path.join(home, ".codex", "session.json");
  const write = sandboxed(profile, ["/bin/sh", "-c", `echo s > ${session}`]);
  assert.equal(write.code, 0);
  assert.equal(fs.existsSync(session), true);
});

test("a sandboxed process cannot create files outside the writable roots", darwin, () => {
  const { home, profile } = fakeHome();
  const evil = path.join(home, "Documents", "evil.txt");
  const r = sandboxed(profile, ["/bin/sh", "-c", `echo x > ${evil}`]);
  assert.notEqual(r.code, 0);
  assert.equal(fs.existsSync(evil), false);
});

test("a sandboxed process cannot delete the user's files", darwin, () => {
  // The damage case: on the Codex backend an MCP tool bypasses `read-only` and
  // `approvalPolicy: "never"` (openai/codex#4152), so the process boundary is
  // what has to stop it.
  const { home, profile } = fakeHome();
  const notes = path.join(home, "Documents", "notes.txt");
  const r = sandboxed(profile, ["/bin/rm", "-f", notes]);
  assert.notEqual(r.code, 0);
  assert.equal(fs.existsSync(notes), true);
});

test("symlinked dotfiles are enforced exactly as real ones", darwin, () => {
  // Found on a real machine: `~/.codex` was a symlink into `~/dotfiles`, so the
  // write allowance named a path the kernel never matches and Codex could not
  // log in. The same miss on `~/.ssh` would leave the keys readable instead.
  const { home, profile } = fakeHome({ symlinkDotfiles: true });
  const secret = sandboxed(profile, ["/bin/cat", path.join(home, ".ssh", "id_rsa")]);
  assert.notEqual(secret.code, 0);
  assert.doesNotMatch(secret.out, /PRIVATE KEY/);

  const session = path.join(home, ".codex", "session.json");
  const write = sandboxed(profile, ["/bin/sh", "-c", `echo s > ${session}`]);
  assert.equal(write.code, 0, "Codex must still be able to write its own state");
  assert.equal(fs.existsSync(session), true);
});

test("the installed wrapper runs the real CLI under the profile", darwin, () => {
  const { home, tmp } = fakeHome();
  // Stand in for the vendored Codex binary: echo whatever it is asked to read.
  const stub = path.join(tmp, "codex-stub");
  fs.writeFileSync(stub, '#!/bin/sh\nexec /bin/cat "$@"\n');
  fs.chmodSync(stub, 0o755);

  const wrapper = installCodexSandbox(tmp, home, stub, [tmp]);
  assert.equal(fs.existsSync(wrapper), true);
  assert.ok(fs.statSync(wrapper).mode & 0o111, "wrapper must be executable");
  assert.match(codexWrapperScript(stub, "/p/advisor.sb"), /^#!\/bin\/sh/);

  const secret = spawnSync(wrapper, [path.join(home, ".ssh", "id_rsa")], { encoding: "utf8" });
  assert.notEqual(secret.status, 0);
  assert.doesNotMatch(secret.stdout ?? "", /PRIVATE KEY/);

  const ordinary = spawnSync(wrapper, [path.join(home, "Documents", "notes.txt")], {
    encoding: "utf8",
  });
  assert.equal(ordinary.status, 0);
  assert.match(ordinary.stdout ?? "", /hello/);
});
