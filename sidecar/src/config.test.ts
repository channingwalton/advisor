import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { readableRoots } from "./toolPolicy.js";
import { effortArg, loadReadableFolders, mergeConfig, modelArg, sessionDirectory } from "./config.js";

test("mergeConfig fills defaults for empty input", () => {
  const c = mergeConfig({});
  assert.equal(c.provider, "claude");
  assert.equal(c.model, "");
});

test("mergeConfig passes the {provider, model} shape through", () => {
  const c = mergeConfig({ provider: "codex", model: "gpt-5-codex" });
  assert.equal(c.provider, "codex");
  assert.equal(c.model, "gpt-5-codex");
});

test("mergeConfig ignores unrecognised legacy keys and keeps defaults", () => {
  const c = mergeConfig({
    classifier: { provider: "codex", models: { codex: "x" } },
    researchModel: "opus",
  });
  assert.equal(c.provider, "claude");
  assert.equal(c.model, "");
});

test("modelArg returns the model or undefined for empty", () => {
  assert.equal(modelArg({ provider: "claude", model: "opus" } as never), "opus");
  assert.equal(modelArg({ provider: "claude", model: "" } as never), undefined);
});

test("mergeConfig coerces non-boolean trigger fields to defaults", () => {
  // The hole: a blind spread let a string/number leak in and be read as a
  // truthy/falsy boolean downstream, silently flipping a trigger kind.
  const c = mergeConfig({ triggers: { question: "yes", context: 0, factcheck: 1 } });
  assert.equal(c.triggers.question, true); // string -> default (true)
  assert.equal(c.triggers.context, true); // 0 -> default (true), not false
  assert.equal(c.triggers.factcheck, true); // 1 -> default (true)
});

test("mergeConfig honours valid boolean trigger fields", () => {
  const c = mergeConfig({ triggers: { question: false, context: true, factcheck: false } });
  assert.equal(c.triggers.question, false);
  assert.equal(c.triggers.context, true);
  assert.equal(c.triggers.factcheck, false);
});

test("mergeConfig drops unknown keys inside triggers", () => {
  const c = mergeConfig({ triggers: { question: false, bogus: true } });
  assert.deepEqual(c.triggers, { question: false, context: true, factcheck: true });
  assert.equal("bogus" in c.triggers, false);
});

test("mergeConfig tolerates a non-object triggers value", () => {
  assert.deepEqual(mergeConfig({ triggers: "nope" }).triggers, {
    question: true,
    context: true,
    factcheck: true,
  });
  assert.deepEqual(mergeConfig({ triggers: null }).triggers, {
    question: true,
    context: true,
    factcheck: true,
  });
});

test("mergeConfig defaults effort to \"\" (inherit the user's Claude setting)", () => {
  assert.equal(mergeConfig({}).effort, "");
});

test("mergeConfig keeps each known effort level", () => {
  for (const level of ["low", "medium", "high", "xhigh", "max"]) {
    assert.equal(mergeConfig({ effort: level }).effort, level);
  }
});

test("mergeConfig drops an unknown or non-string effort to the default", () => {
  // A typo or a level from a newer app must not reach the SDK as a bad option.
  assert.equal(mergeConfig({ effort: "turbo" }).effort, "");
  assert.equal(mergeConfig({ effort: 3 }).effort, "");
});

test("effortArg returns the level, or undefined to inherit", () => {
  assert.equal(effortArg(mergeConfig({ effort: "low" })), "low");
  assert.equal(effortArg(mergeConfig({})), undefined);
});

test("mergeConfig keeps transcript text out of the log unless logTranscriptText is true", () => {
  assert.equal(mergeConfig({}).logTranscriptText, false);
  assert.equal(mergeConfig({ logTranscriptText: "yes" }).logTranscriptText, false);
  assert.equal(mergeConfig({ logTranscriptText: true }).logTranscriptText, true);
});

test("#sandbox-readable-folders mergeConfig lists no readable folder by default and keeps only strings", () => {
  assert.deepEqual(mergeConfig({}).readableFolders, []);
  assert.deepEqual(mergeConfig({ readableFolders: ["/a", 5, null, "~/b"] }).readableFolders, ["/a", "~/b"]);
  assert.deepEqual(mergeConfig({ readableFolders: "/a" }).readableFolders, []);
});

test("#sandbox-readable-folders loadReadableFolders adds session history and fails closed on invalid config", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "advisor-config-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "config.json");
  assert.deepEqual(loadReadableFolders(file), [path.join(os.homedir(), "Library/Application Support/Advisor/sessions")]); // no file uses the app default
  fs.writeFileSync(file, JSON.stringify({ provider: "claude", readableFolders: ["~/Notes", "/Users/x/dev"] }));
  const sessions = path.join(os.homedir(), "Library/Application Support/Advisor/sessions");
  assert.deepEqual(loadReadableFolders(file), ["~/Notes", "/Users/x/dev", sessions]);
  fs.writeFileSync(file, JSON.stringify({ readableFolders: ["/Users/x/dev"] }));
  assert.deepEqual(loadReadableFolders(file), ["/Users/x/dev", sessions]); // a removal applies at once
  for (const body of ["{not json", "null", "[]", "\"x\""]) {
    fs.writeFileSync(file, body);
    assert.deepEqual(loadReadableFolders(file), [], body);
  }
});

test("#session-history session directory mirrors the app's blank, tilde and relative path rules", () => {
  const home = "/Users/example";
  const fallback = `${home}/Library/Application Support/Advisor/sessions`;
  for (const value of [undefined, "", "  ", "relative/path", 3]) {
    assert.equal(sessionDirectory(value, home), fallback);
  }
  assert.equal(sessionDirectory("  ~/History  ", home), `${home}/History`);
  assert.equal(sessionDirectory("~", home), home);
  assert.equal(sessionDirectory(" /Volumes/History ", home), "/Volumes/History");
  assert.equal(mergeConfig({ sessionDir: "~/History" }).sessionDir, "~/History");
  assert.equal(mergeConfig({ sessionDir: 3 }).sessionDir, "");
});

test("#session-history the effective folders follow session folder edits without persisting an allowance", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "advisor-history-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "config.json");
  fs.writeFileSync(file, JSON.stringify({ readableFolders: ["~/Notes"], sessionDir: "~/History" }));
  assert.deepEqual(loadReadableFolders(file), ["~/Notes", path.join(os.homedir(), "History")]);
  fs.writeFileSync(file, JSON.stringify({ readableFolders: [], sessionDir: "~/Other" }));
  assert.deepEqual(loadReadableFolders(file), [path.join(os.homedir(), "Other")]);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).readableFolders, []);
});

test("#session-history the implicit archive cannot open credentials, broad parents, symlinks into stores or paths outside home", (t) => {
  const home = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "advisor-history-policy-")));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const file = path.join(home, "config.json");
  fs.mkdirSync(path.join(home, ".ssh"));
  fs.symlinkSync(path.join(home, ".ssh"), path.join(home, "HistoryLink"));
  for (const folder of [home, path.join(home, "Library"), path.join(home, ".ssh"), path.join(home, "HistoryLink"), path.dirname(home)]) {
    fs.writeFileSync(file, JSON.stringify({ readableFolders: [], sessionDir: folder }));
    assert.deepEqual(readableRoots(home, loadReadableFolders(file)), [], folder);
  }
  const archive = path.join(home, "Library/Application Support/Advisor/sessions");
  fs.writeFileSync(file, JSON.stringify({ sessionDir: archive }));
  assert.ok(readableRoots(home, loadReadableFolders(file)).includes(archive));
});
