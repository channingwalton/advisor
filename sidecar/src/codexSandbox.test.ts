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
  sandboxWriteDenials,
  seatbeltProfile,
  writeCodexProfile,
  type ReadAllowance,
  type SeatbeltPolicy,
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
  for (const d of ["Documents", "tmp", "Private", "cli", "Library/cwd"]) {
    fs.mkdirSync(path.join(home, d), { recursive: true });
  }
  // An ordinary folder that the user does not list as readable.
  fs.writeFileSync(path.join(home, "Private", "plan.txt"), "private plan");
  fs.writeFileSync(path.join(home, "cli", "helper.txt"), "cli file");
  fs.writeFileSync(path.join(home, "Library", "cwd", "AGENTS.md"), "cwd file");

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
  fs.writeFileSync(profile, seatbeltProfile(sandboxPolicy(home, readsOf(home), [tmp])));
  return { home, tmp, profile };
}

/// What the fake home lets the sandboxed process read: `~/Documents`, the CLI
/// folder and the working folder.
function readsOf(home: string, folders = [path.join(home, "Documents")]): ReadAllowance {
  return { folders, cliRoot: path.join(home, "cli"), cwd: path.join(home, "Library", "cwd") };
}

/// A policy with only the given rules, for tests of the profile text.
function rules(given: Partial<SeatbeltPolicy>): SeatbeltPolicy {
  return {
    home: [], readRoots: [], readPatterns: [], readMetadata: [], readDenials: [], confineWrites: true, writableRoots: [], writePatterns: [], writeDenials: [],
    ...given,
  };
}

function sandboxed(profile: string, argv: string[]): { code: number; out: string; err: string } {
  const r = spawnSync("/usr/bin/sandbox-exec", ["-f", profile, ...argv], { encoding: "utf8" });
  return { code: r.status ?? -1, out: r.stdout ?? "", err: r.stderr ?? "" };
}

test("the OS sandbox denies every path the Claude backend denies, bar Codex's own state", () => {
  // The denials that the profile ships (`storeDenials`, code review 2026-11-14).
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-codex-deny-")));
  const denied = sandboxPolicy(home, { folders: [], cliRoot: "/opt/codex", cwd: path.join(home, "cwd") }, ["/tmp"]).readDenials;
  try {
    for (const p of deniedPaths(home)) {
      const providerState = p === path.join(home, ".codex") || p === path.join(home, ".codex-global-state.json");
      assert.equal(denied.includes(p), !providerState, p);
    }
    // Parity is the point: one denylist, both backends.
    assert.equal(denied.length, deniedPaths(home).length - 2);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test("the profile denies the read paths and confines writes to the writable roots", () => {
  const profile = seatbeltProfile(rules({ readDenials: ["/home/u/.ssh"], writableRoots: ["/home/u/.codex"] }));
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
  const profile = seatbeltProfile(rules({
    writableRoots: ["/home/u/.codex"], writeDenials: ["/home/u/.codex/config.toml", "/home/u/.codex/skills"],
  }));
  assert.match(profile, /\(deny file-write\* \(subpath "\/home\/u\/\.codex\/config\.toml"\) \(subpath "\/home\/u\/\.codex\/skills"\)\)/);
  // Last matching rule wins: the input denials must follow the folder allowance.
  assert.ok(profile.indexOf("(allow file-write*") < profile.indexOf('(deny file-write* (subpath "/home/u/.codex/config.toml"'));
});

test("the policy names every input as a write denial, resolved through the folder", () => {
  const { home } = fakeHome({ symlinkDotfiles: true });
  const policy = sandboxPolicy(home, readsOf(home), [path.join(home, "tmp")]);
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
  const policy = sandboxPolicy(home, readsOf(home), [path.join(home, "tmp")]);
  assert.ok(policy.writeDenials.includes(path.join(home, "dotfiles", "shared", "config.toml")), policy.writeDenials.join("\n"));
});

test("a dangling link into a folder that does not exist yet is still denied at its real target", () => {
  const { home } = fakeHome({ symlinkDotfiles: true });
  const real = path.join(home, "dotfiles", ".codex");
  fs.symlinkSync(path.join(home, ".codex", "local", "hooks.json"), path.join(real, "hooks.json"));
  const policy = sandboxPolicy(home, readsOf(home), [path.join(home, "tmp")]);
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
  const policy = sandboxPolicy(home, readsOf(home), [path.join(home, "tmp")]);
  for (const p of [path.join(codex, "config.toml"), target, path.join(codex, "hooks.json"), dangling]) {
    assert.ok(policy.writeDenials.includes(p), `${p} missing from\n${policy.writeDenials.join("\n")}`);
  }
});

test("profile paths are escaped so a quote cannot terminate the s-expression", () => {
  const profile = seatbeltProfile(rules({ readDenials: ['/home/u/a"b\\c'] }));
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

// GHSA-6xc8-f55f-jxqr: a denylist fails open for each store that it does not
// name, so Codex reads in the home folder only the folders that the user lists
// as readable, and what the CLI needs to run.
test("#codex-readable-folders the profile reads the home folder only where it allows, and the stores never", () => {
  const profile = seatbeltProfile(rules({
    home: ["/home/u"], readRoots: ["/home/u/Documents"], readMetadata: ["/home/u"], readDenials: ["/home/u/.ssh"],
  }));
  const at = (rule: string): number => {
    assert.ok(profile.includes(rule), rule);
    return profile.indexOf(rule);
  };
  const home = at('(deny file-read* (subpath "/home/u"))');
  const roots = at('(allow file-read* (subpath "/home/u/Documents"))');
  const metadata = at('(allow file-read-metadata (literal "/home/u"))');
  const stores = at('(deny file-read* (subpath "/home/u/.ssh"))');
  // Seatbelt takes the last matching rule.
  assert.ok(home < roots && home < metadata, "the allowances follow the home denial");
  assert.ok(roots < stores && metadata < stores, "the store denials come last");
});

test("#codex-readable-folders the policy allows the readable folders, Codex's state, the CLI and the working folder", () => {
  const { home } = fakeHome({ symlinkDotfiles: true });
  const listed = [path.join(home, "Documents"), "~", path.join(home, ".ssh"), "~/Library", "~/dotfiles"];
  const policy = sandboxPolicy(home, readsOf(home, listed), [path.join(home, "tmp")]);
  assert.deepEqual(policy.home, [home]);
  for (const p of ["Documents", ".codex", "dotfiles/.codex", ".codex-global-state.json", "cli", "Library/cwd"]) {
    assert.ok(policy.readRoots.includes(path.join(home, p)), p);
  }
  // The listed folders that the policy refuses: the home folder, a store, and
  // folders above a store.
  for (const p of [home, path.join(home, ".ssh"), path.join(home, "dotfiles", ".ssh"), path.join(home, "Library"),
    path.join(home, "dotfiles")]) {
    assert.ok(!policy.readRoots.includes(p), p);
  }
  // Only the metadata of the folders on the way, so that a path can be resolved.
  assert.deepEqual(
    [...policy.readMetadata].sort(),
    [home, path.join(home, "Library"), path.join(home, "dotfiles")].sort()
  );
});

test("#codex-readable-folders a sandboxed process reads in the home folder only the readable folders and what Codex needs", darwin, () => {
  for (const layout of [{}, { symlinkDotfiles: true }]) {
    const { home, profile } = fakeHome(layout);
    const label = JSON.stringify(layout);
    const refused = sandboxed(profile, ["/bin/cat", path.join(home, "Private", "plan.txt")]);
    assert.notEqual(refused.code, 0, label);
    assert.doesNotMatch(refused.out, /private plan/, label);
    const listing = sandboxed(profile, ["/bin/ls", home]);
    assert.notEqual(listing.code, 0, label);
    assert.doesNotMatch(listing.out, /Private/, label);
    for (const [file, text] of [
      ["Documents/notes.txt", "hello"], ["cli/helper.txt", "cli file"], ["Library/cwd/AGENTS.md", "cwd file"],
      [".codex/auth.json", "provider token"],
    ]) {
      const r = sandboxed(profile, ["/bin/cat", path.join(home, file)]);
      assert.equal(r.code, 0, `${label} ${file}: ${r.err}`);
      assert.match(r.out, new RegExp(text), `${label} ${file}`);
    }
    // A path to an allowed folder can be resolved: the folders on the way give
    // their metadata.
    const resolved = sandboxed(profile, ["/bin/realpath", path.join(home, ".codex", "auth.json")]);
    assert.equal(resolved.code, 0, `${label}: ${resolved.err}`);
  }
});

test("#codex-readable-folders a profile written again follows the folders that the user lists now", darwin, () => {
  const { home, tmp } = fakeHome();
  const notes = path.join(home, "Documents", "notes.txt");
  const profile = writeCodexProfile(tmp, home, readsOf(home), [tmp]);
  assert.match(sandboxed(profile, ["/bin/cat", notes]).out, /hello/);
  // The user removes the folder: the next CLI that starts cannot read it.
  assert.equal(writeCodexProfile(tmp, home, readsOf(home, []), [tmp]), profile);
  const removed = sandboxed(profile, ["/bin/cat", notes]);
  assert.notEqual(removed.code, 0);
  assert.doesNotMatch(removed.out, /hello/);
  // The user adds another folder, in the `~` form that the Files tab can store.
  writeCodexProfile(tmp, home, readsOf(home, ["~/Private"]), [tmp]);
  assert.match(sandboxed(profile, ["/bin/cat", path.join(home, "Private", "plan.txt")]).out, /private plan/);
});

// A temporary folder in the home folder (a `TMPDIR` such as `~/tmp`): what the
// CLI and its connectors write there, they must read back (code review
// 2026-11-11).
test("#codex-readable-folders a sandboxed process reads back what it writes in a temporary folder in the home folder", darwin, () => {
  const { tmp, profile } = fakeHome();
  const scratch = path.join(tmp, "scratch.txt");
  const r = sandboxed(profile, ["/bin/sh", "-c", `echo scratch > ${scratch} && /bin/cat ${scratch}`]);
  assert.equal(r.code, 0, r.err);
  assert.match(r.out, /scratch/);
  // A `TMPDIR` in another letter case than the home folder: the default
  // volume and Seatbelt ignore the case, so the profile must too.
  const { home: other } = fakeHome();
  const spelt = path.join(path.dirname(other), path.basename(other).toUpperCase(), "TMP", "DEEP");
  fs.mkdirSync(spelt, { recursive: true });
  const caseProfile = path.join(other, "tmp", "case.sb");
  fs.writeFileSync(caseProfile, seatbeltProfile(sandboxPolicy(other, readsOf(other), [spelt])));
  const deep = path.join(spelt, "scratch.txt");
  const back = sandboxed(caseProfile, ["/bin/sh", "-c", `echo scratch > ${deep} && /bin/cat ${deep} && /bin/realpath ${deep}`]);
  assert.equal(back.code, 0, back.err);
});

// A `TMPDIR` that holds stores, such as `~/Library`, is neither read nor
// written. As a read root it would open every store in it that the denylist
// does not name. As a writable root it would let a process move a store out to
// `/tmp`, which it can write and read (code review 2026-11-14). A temp root is
// judged as a listed folder is (`readableRoots`), and so are the CLI and
// working folders (code review 2026-11-11).
test("#codex-readable-folders a temporary folder that holds stores is not opened to reads or writes", darwin, () => {
  const { home } = fakeHome();
  const library = path.join(home, "Library");
  fs.mkdirSync(path.join(library, "Mail"));
  fs.writeFileSync(path.join(library, "Mail", "inbox.txt"), "private mail");
  const policy = sandboxPolicy(home, readsOf(home), [library, "/private/tmp"]);
  assert.ok(!policy.readRoots.includes(library), policy.readRoots.join("\n"));
  assert.ok(!policy.writableRoots.includes(library), policy.writableRoots.join("\n"));
  assert.ok(policy.writableRoots.includes("/private/tmp"), "a temp folder outside the home folder stays writable");
  // Nor a temp folder above the home folder, which holds every store in it.
  const above = sandboxPolicy(home, readsOf(home), [path.dirname(home), "/"]).writableRoots;
  assert.ok(!above.includes(path.dirname(home)) && !above.includes("/"), above.join("\n"));
  const profile = path.join(home, "tmp", "library.sb");
  fs.writeFileSync(profile, seatbeltProfile(policy));
  const r = sandboxed(profile, ["/bin/cat", path.join(library, "Mail", "inbox.txt")]);
  assert.notEqual(r.code, 0);
  assert.doesNotMatch(r.out, /private mail/);
  // A CLI or working folder that holds a store is not a read root either.
  const wide = sandboxPolicy(home, { ...readsOf(home), cliRoot: library, cwd: home }, [path.join(home, "tmp")]);
  assert.ok(!wide.readRoots.includes(library) && !wide.readRoots.includes(home), wide.readRoots.join("\n"));
});

// The first run in a home reached through a symlink: `~/.codex` does not exist
// yet, and a rule that names it through the link would match nothing, because
// the kernel matches resolved paths. Codex could then not log in (code review
// 2026-11-11).
test("#codex-readable-folders Codex makes and reads its state on a first run in a home reached through a symlink", darwin, () => {
  const { home: real } = fakeHome();
  fs.rmSync(path.join(real, ".codex"), { recursive: true });
  const home = `${real}-link`;
  fs.symlinkSync(real, home);
  const tmp = path.join(home, "tmp");
  const profile = writeCodexProfile(tmp, home, readsOf(home), [tmp]);
  const auth = path.join(home, ".codex", "auth.json");
  const make = sandboxed(profile, ["/bin/sh", "-c", `mkdir ${path.dirname(auth)} && echo token > ${auth}`]);
  assert.equal(make.code, 0, make.err);
  assert.match(sandboxed(profile, ["/bin/cat", auth]).out, /token/);
});

// `$HOME` in another letter case than the disk stores it, and a folder listed
// in the stored spelling, as the folder picker gives it. The folders on the
// way to it must still give their metadata, or no path in it can be resolved
// (code review 2026-11-11).
test("#codex-readable-folders a path in a readable folder resolves when $HOME is in another letter case", darwin, () => {
  const { home: real } = fakeHome();
  const notes = path.join(real, "Documents", "Notes");
  fs.mkdirSync(notes);
  fs.writeFileSync(path.join(notes, "a.md"), "note");
  const home = path.join(path.dirname(real), path.basename(real).toUpperCase());
  const tmp = path.join(home, "tmp");
  const profile = writeCodexProfile(tmp, home, readsOf(home, [notes]), [tmp]);
  const resolved = sandboxed(profile, ["/bin/realpath", path.join(notes, "a.md")]);
  assert.equal(resolved.code, 0, resolved.err);
  assert.match(sandboxed(profile, ["/bin/cat", path.join(notes, "a.md")]).out, /note/);
});

/// Run `script` in a new Node process whose home folder is `home`, as the
/// sidecar runs: `codexSandboxWrapper` installs the sandbox there and reads
/// that home's config.json. The script gets this module as `m`.
function inSidecar(home: string, script: string): void {
  const url = new URL("./codexSandbox.js", import.meta.url).href;
  const r = spawnSync(
    process.execPath,
    ["--input-type=module", "-e", `const m = await import(${JSON.stringify(url)});\n${script}`],
    { env: { PATH: process.env.PATH ?? "", HOME: home, TMPDIR: os.tmpdir() }, encoding: "utf8" }
  );
  assert.equal(r.status, 0, r.stderr);
}

// The sidecar's own install and the write before each turn, with the list from
// config.json. The home folder is reached through a symlink, and the folder is
// listed in that form, as the folder picker gives it: Claude reads such a
// folder, so Codex must too (code review 2026-11-11).
test("#codex-readable-folders the sidecar's sandbox follows config.json at each turn, in a home reached through a symlink", darwin, () => {
  const { home: real } = fakeHome();
  const home = `${real}-link`;
  fs.symlinkSync(real, home);
  const advisor = path.join(home, "Library", "Application Support", "Advisor");
  fs.mkdirSync(advisor, { recursive: true });
  const config = path.join(advisor, "config.json");
  const profile = path.join(advisor, "sandbox", "advisor.sb");
  const notes = path.join(home, "Documents", "notes.txt");
  fs.writeFileSync(config, JSON.stringify({ readableFolders: [path.join(home, "Documents")] }));
  inSidecar(home, "m.codexSandboxWrapper();");
  const listed = sandboxed(profile, ["/bin/cat", notes]);
  assert.match(listed.out, /hello/, listed.err);
  // The user removes the folder after the install: the next turn's write
  // reads config.json again.
  inSidecar(home, [
    "m.codexSandboxWrapper();",
    `(await import("node:fs")).writeFileSync(${JSON.stringify(config)}, '{"readableFolders":[]}');`,
    "m.refreshCodexSandbox();",
  ].join("\n"));
  const removed = sandboxed(profile, ["/bin/cat", notes]);
  assert.notEqual(removed.code, 0);
  assert.doesNotMatch(removed.out, /hello/);
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
  fs.writeFileSync(profile, seatbeltProfile(sandboxPolicy(home, readsOf(home), [tmp])));
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
  const profile = seatbeltProfile(rules({ writableRoots: ["/home/u/.codex"] }));
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

  const wrapper = installCodexSandbox(tmp, home, stub, { ...readsOf(home), cliRoot: tmp }, [tmp]);
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
