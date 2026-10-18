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
  sandboxWriteDenials,
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
  fs.writeFileSync(path.join(root, ".codex", "config.toml"), 'model = "x"\n');
  fs.writeFileSync(path.join(home, "Documents", "notes.txt"), "hello");

  const tmp = path.join(home, "tmp");
  const profile = path.join(tmp, "advisor.sb");
  const policy = sandboxPolicy(home, [tmp]);
  fs.writeFileSync(profile, seatbeltProfile(policy.readDenials, policy.writableRoots, policy.writeDenials));
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
  const profile = seatbeltProfile(["/home/u/.ssh"], ["/home/u/.codex"], []);
  assert.match(profile, /^\(version 1\)/);
  assert.match(profile, /\(deny file-read\* \(subpath "\/home\/u\/\.ssh"\)\)/);
  assert.match(profile, /\(deny file-write\*\)/);
  assert.match(profile, /\(allow file-write\* \(subpath "\/home\/u\/\.codex"\)\)/);
  // No Apple Events, no launchers: `osascript -e 'tell app "Finder" to do shell
  // script …'` would run the script in Finder's process, `open`/`launchctl`
  // hand one to launchd — outside this profile either way.
  assert.match(profile, /\(deny appleevent-send\)/);
  assert.match(profile, /\(deny process-exec \(literal "\/usr\/bin\/osascript"\) \(literal "\/usr\/bin\/open"\) \(literal "\/bin\/launchctl"\) \(literal "\/usr\/bin\/shortcuts"\)\)/);
  // The allow must follow the deny: Seatbelt takes the last matching rule.
  assert.ok(profile.indexOf("(deny file-write*)") < profile.indexOf("(allow file-write*"));
});

test("the profile denies writes to Codex's inputs, after the folder allowance", () => {
  const profile = seatbeltProfile([], ["/home/u/.codex"], ["/home/u/.codex/config.toml", "/home/u/.codex/skills"]);
  assert.match(profile, /\(deny file-write\* \(subpath "\/home\/u\/\.codex\/config\.toml"\) \(subpath "\/home\/u\/\.codex\/skills"\)\)/);
  // Last matching rule wins: the input denials must follow the folder allowance.
  assert.ok(profile.indexOf("(allow file-write*") < profile.indexOf('(deny file-write* (subpath "/home/u/.codex/config.toml"'));
});

test("the policy names every input as a write denial, resolved through the folder", () => {
  const { home } = fakeHome({ symlinkDotfiles: true });
  const policy = sandboxPolicy(home, [path.join(home, "tmp")]);
  const real = path.join(home, "dotfiles", ".codex");
  const inputs = sandboxWriteDenials(home);
  assert.ok(inputs.length >= 9, "the input list is not empty");
  for (const input of inputs) {
    assert.equal(path.dirname(input), path.join(home, ".codex"), input);
    assert.ok(policy.writeDenials.includes(path.join(real, path.basename(input))), input);
  }
  // The connector-override and command-running inputs are in the list by name.
  for (const f of ["config.toml", "managed_config.toml", "hooks.json", ".env", "AGENTS.md", "skills"]) {
    assert.ok(inputs.includes(path.join(home, ".codex", f)), f);
  }
});

test("a relative symlink target is read from the folder the link really sits in", () => {
  // Dotfiles managers write relative links; resolved against the unresolved
  // `~/.codex` the denied target would be a path the kernel never matches.
  const { home } = fakeHome({ symlinkDotfiles: true });
  const real = path.join(home, "dotfiles", ".codex");
  fs.mkdirSync(path.join(home, "dotfiles", "shared"));
  fs.writeFileSync(path.join(home, "dotfiles", "shared", "config.toml"), "");
  fs.unlinkSync(path.join(real, "config.toml"));
  fs.symlinkSync("../shared/config.toml", path.join(real, "config.toml"));
  const policy = sandboxPolicy(home, [path.join(home, "tmp")]);
  assert.ok(policy.writeDenials.includes(path.join(home, "dotfiles", "shared", "config.toml")), policy.writeDenials.join("\n"));
});

test("a dangling link into a folder that does not exist yet is still denied at its real target", () => {
  const { home } = fakeHome({ symlinkDotfiles: true });
  const real = path.join(home, "dotfiles", ".codex");
  fs.symlinkSync(path.join(home, ".codex", "local", "hooks.json"), path.join(real, "hooks.json"));
  const policy = sandboxPolicy(home, [path.join(home, "tmp")]);
  assert.ok(policy.writeDenials.includes(path.join(real, "local", "hooks.json")), policy.writeDenials.join("\n"));
});

test("an input that is itself a symlink is denied by name and at its target, dangling or not", () => {
  const { home } = fakeHome();
  const codex = path.join(home, ".codex");
  const target = path.join(home, "Documents", "work.toml");
  fs.writeFileSync(target, "");
  fs.unlinkSync(path.join(codex, "config.toml"));
  fs.symlinkSync(target, path.join(codex, "config.toml"));
  const dangling = path.join(codex, "local", "hooks.json"); // not created
  fs.symlinkSync(dangling, path.join(codex, "hooks.json"));
  const policy = sandboxPolicy(home, [path.join(home, "tmp")]);
  for (const p of [path.join(codex, "config.toml"), target, path.join(codex, "hooks.json"), dangling]) {
    assert.ok(policy.writeDenials.includes(p), `${p} missing from\n${policy.writeDenials.join("\n")}`);
  }
});

test("profile paths are escaped so a quote cannot terminate the s-expression", () => {
  const profile = seatbeltProfile(['/home/u/a"b\\c'], [], []);
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

// The inputs that shape the CLI's next turn or session (see sandboxWriteDenials)
// are write-denied inside the otherwise writable folder, in both home layouts.
test("a sandboxed process cannot write Codex's inputs, by write, rename or new file", darwin, () => {
  for (const layout of [{}, { symlinkDotfiles: true }]) {
    const { home, profile } = fakeHome(layout);
    const label = JSON.stringify(layout);
    const config = path.join(home, ".codex", "config.toml");
    const append = sandboxed(profile, ["/bin/sh", "-c", `echo '[mcp_servers.evil]' >> ${config}`]);
    assert.notEqual(append.code, 0, label);
    assert.equal(fs.readFileSync(config, "utf8"), 'model = "x"\n');
    const staged = path.join(home, ".codex", "config.toml.tmp");
    const rename = sandboxed(profile, ["/bin/sh", "-c", `echo evil > ${staged} && mv ${staged} ${config}`]);
    assert.notEqual(rename.code, 0, label);
    assert.equal(fs.readFileSync(config, "utf8"), 'model = "x"\n');
    // Files that need not exist yet, and a folder of them.
    for (const f of ["managed_config.toml", "requirements.toml", "hooks.json", "AGENTS.md"]) {
      const target = path.join(home, ".codex", f);
      const r = sandboxed(profile, ["/bin/sh", "-c", `echo evil > ${target}`]);
      assert.notEqual(r.code, 0, `${label} ${f}`);
      assert.equal(fs.existsSync(target), false, `${label} ${f}`);
    }
    // The volume is case-insensitive and so is the kernel's match: a case
    // variant of a denied name cannot be created either.
    const upper = path.join(home, ".codex", "HOOKS.JSON");
    const cased = sandboxed(profile, ["/bin/sh", "-c", `echo evil > ${upper}`]);
    assert.notEqual(cased.code, 0, label);
    assert.equal(fs.existsSync(upper), false, label);
    const skill = path.join(home, ".codex", "skills", "evil", "SKILL.md");
    const mk = sandboxed(profile, ["/bin/sh", "-c", `mkdir -p ${path.dirname(skill)} && echo evil > ${skill}`]);
    assert.notEqual(mk.code, 0, label);
    assert.equal(fs.existsSync(skill), false, label);
    // Reading them is still fine, and the rest of the folder is still writable
    // (the "can still read and write Codex's own state" test above).
    const read = sandboxed(profile, ["/bin/cat", config]);
    assert.equal(read.code, 0, label);
    // Seatbelt matches paths, not inodes, but linking needs write access to the
    // source path, so a hard link cannot lend a denied file an allowed name.
    const alias = path.join(home, ".codex", "alias.toml");
    const hard = sandboxed(profile, ["/bin/sh", "-c", `ln ${config} ${alias} && echo '[mcp_servers.evil]' >> ${alias}`]);
    assert.notEqual(hard.code, 0, label);
    assert.equal(fs.readFileSync(config, "utf8"), 'model = "x"\n');
  }
});

test("a config.toml that is a symlink cannot be written through the link, nor replaced", darwin, () => {
  const { home, tmp } = fakeHome();
  const target = path.join(home, ".codex", "profiles", "work.toml");
  fs.mkdirSync(path.dirname(target));
  fs.writeFileSync(target, 'model = "x"\n');
  const link = path.join(home, ".codex", "config.toml");
  fs.unlinkSync(link);
  fs.symlinkSync(target, link);
  const profile = path.join(tmp, "advisor.sb");
  const policy = sandboxPolicy(home, [tmp]);
  fs.writeFileSync(profile, seatbeltProfile(policy.readDenials, policy.writableRoots, policy.writeDenials));
  const through = sandboxed(profile, ["/bin/sh", "-c", `echo '[mcp_servers.evil]' >> ${link}`]);
  assert.notEqual(through.code, 0);
  assert.equal(fs.readFileSync(target, "utf8"), 'model = "x"\n');
  const replace = sandboxed(profile, ["/bin/sh", "-c", `rm ${link} && echo '[mcp_servers.evil]' > ${link}`]);
  assert.notEqual(replace.code, 0);
  assert.ok(fs.lstatSync(link).isSymbolicLink(), "the link must survive");
  assert.equal(fs.readFileSync(target, "utf8"), 'model = "x"\n');
});

test("a sandboxed process cannot run the launchers", darwin, () => {
  const { profile } = fakeHome();
  // Pure arithmetic: no Apple Event to another app, so no TCC prompt — the
  // exec itself is what must be refused.
  const r = sandboxed(profile, ["/usr/bin/osascript", "-e", "1 + 1"]);
  assert.notEqual(r.code, 0);
  assert.doesNotMatch(r.out, /^2/);
  const o = sandboxed(profile, ["/usr/bin/open", "--help"]);
  assert.notEqual(o.code, 0);
});

test("the profile denies the LaunchServices mach services", () => {
  // The exec denial only stops the launcher *binaries*. A process can reach
  // LaunchServices directly — `LSOpenCFURLRef` over mach/XPC — and hand a
  // program to launchd without ever running `open`. Denying the `com.apple.lsd`
  // family at the mach port closes that route; the family (bare `com.apple.lsd`
  // plus every `com.apple.lsd.*` sub-service) must be matched by regex, since an
  // explicit `com.apple.lsd`/`launchservicesd` list leaves resolution working
  // through the sub-services. Verified live below.
  const profile = seatbeltProfile([], ["/home/u/.codex"], []);
  assert.match(profile, /\(deny mach-lookup \(global-name-regex "\^com\\\.apple\\\.lsd"\)\)/);
  // After the launcher exec denial, before the write rules — it is a deny, so
  // position only matters against a later allow, and there is no mach allow.
  assert.ok(profile.indexOf("(deny process-exec") < profile.indexOf("(deny mach-lookup"));
});

/// Compile a launch-free LaunchServices probe: it *resolves* the default handler
/// for an `https` URL (no app is launched) and exits 0 when LS answered, non-0
/// when the port was unreachable. Returns its path, or undefined when the
/// toolchain to build it is absent (then the live test below self-skips).
function launchServicesProbe(dir: string): string | undefined {
  const src = path.join(dir, "ls-resolve.c");
  const bin = path.join(dir, "ls-resolve");
  fs.writeFileSync(
    src,
    `#include <CoreServices/CoreServices.h>\n#include <stdio.h>\n` +
      `int main(void){ CFURLRef in=CFURLCreateWithString(NULL,CFSTR("https://example.com"),NULL);\n` +
      ` CFErrorRef e=NULL; CFURLRef a=LSCopyDefaultApplicationURLForURL(in,kLSRolesAll,&e);\n` +
      ` if(a){printf("resolved\\n");return 0;} printf("unreachable %ld\\n",e?(long)CFErrorGetCode(e):-1L);return 3; }\n`
  );
  const cc = spawnSync("/usr/bin/clang", ["-framework", "CoreServices", "-o", bin, src], { encoding: "utf8" });
  return cc.status === 0 && fs.existsSync(bin) ? bin : undefined;
}

test("a sandboxed process cannot reach LaunchServices to launch a program", darwin, (t) => {
  const { home, profile } = fakeHome();
  const probe = launchServicesProbe(home);
  if (!probe) return t.skip("no clang/CoreServices toolchain to build the probe");
  // Unsandboxed the probe resolves a handler — LS is reachable on this machine.
  assert.equal(spawnSync(probe, { encoding: "utf8" }).status, 0, "probe should resolve unsandboxed");
  // Under the profile LS is unreachable, so nothing can be resolved — hence
  // nothing launched — through the library route either.
  const r = sandboxed(profile, [probe]);
  assert.notEqual(r.code, 0);
  assert.match(r.out, /unreachable/);
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
