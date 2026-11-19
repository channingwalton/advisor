import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { effortArg, loadPastSessionsFolder, loadReadableFolders, mergeConfig, modelArg, sessionFolder } from "./config.js";

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

test("#sandbox-readable-folders loadReadableFolders reads the file as it is now, and gives none on any failure", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "advisor-config-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "config.json");
  assert.deepEqual(loadReadableFolders(file), []); // no file
  fs.writeFileSync(file, JSON.stringify({ provider: "claude", readableFolders: ["~/Notes", "/Users/x/dev"] }));
  assert.deepEqual(loadReadableFolders(file), ["~/Notes", "/Users/x/dev"]);
  fs.writeFileSync(file, JSON.stringify({ readableFolders: ["/Users/x/dev"] }));
  assert.deepEqual(loadReadableFolders(file), ["/Users/x/dev"]); // a removal applies at once
  for (const body of ["{not json", "null", "[]", "\"x\""]) {
    fs.writeFileSync(file, body);
    assert.deepEqual(loadReadableFolders(file), [], body);
  }
});

test("#past-sessions mergeConfig reads past sessions only when readPastSessions is true", () => {
  assert.equal(mergeConfig({}).readPastSessions, false);
  assert.equal(mergeConfig({ readPastSessions: "yes" }).readPastSessions, false);
  assert.equal(mergeConfig({ readPastSessions: true }).readPastSessions, true);
  assert.equal(mergeConfig({}).sessionDir, "");
  assert.equal(mergeConfig({ sessionDir: 5 }).sessionDir, "");
  assert.equal(mergeConfig({ sessionDir: "/Users/x/S" }).sessionDir, "/Users/x/S");
});

// The app's rule (`SessionArchive.directory(for:)`), so the agents read the
// folder that the app writes.
test("#past-sessions sessionFolder resolves sessionDir as the app does", () => {
  const home = "/Users/x";
  const fallback = "/Users/x/Library/Application Support/Advisor/sessions";
  assert.equal(sessionFolder("", home), fallback);
  assert.equal(sessionFolder("relative/S", home), fallback);
  assert.equal(sessionFolder(" \t/Users/x/S \u00a0", home), "/Users/x/S");
  assert.equal(sessionFolder("~/S", home), "/Users/x/S");
  assert.equal(sessionFolder("~", home), "/Users/x");
  // The app trims spaces and tabs only, so a newline stays in the name.
  assert.equal(sessionFolder("/Users/x/S\n", home), "/Users/x/S\n");
  // Another user's home: the app finds it, the sidecar cannot be sure of it.
  assert.equal(sessionFolder("~other/S", home), null);
});

test("#past-sessions loadReadableFolders adds the session folder while readPastSessions is on", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "advisor-config-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "config.json");
  const home = "/Users/x";
  const fallback = "/Users/x/Library/Application Support/Advisor/sessions";
  fs.writeFileSync(file, JSON.stringify({ readableFolders: ["~/Notes"], sessionDir: "/Users/x/S" }));
  assert.deepEqual(loadReadableFolders(file, home), ["~/Notes"]);
  assert.equal(loadPastSessionsFolder(file, home), null);
  fs.writeFileSync(file, JSON.stringify({ readableFolders: ["~/Notes"], readPastSessions: true }));
  assert.deepEqual(loadReadableFolders(file, home), ["~/Notes", fallback]);
  assert.equal(loadPastSessionsFolder(file, home), fallback);
  fs.writeFileSync(file, JSON.stringify({ readPastSessions: true, sessionDir: "/Users/x/S" }));
  assert.deepEqual(loadReadableFolders(file, home), ["/Users/x/S"]);
  assert.equal(loadPastSessionsFolder(file, home), "/Users/x/S");
  fs.writeFileSync(file, JSON.stringify({ readPastSessions: true, sessionDir: "~other/S" }));
  assert.deepEqual(loadReadableFolders(file, home), []);
  // The user turns it off: the next call reads no session.
  fs.writeFileSync(file, JSON.stringify({ readPastSessions: false, sessionDir: "/Users/x/S" }));
  assert.deepEqual(loadReadableFolders(file, home), []);
  assert.equal(loadPastSessionsFolder(file, home), null);
  fs.writeFileSync(file, "{not json");
  assert.equal(loadPastSessionsFolder(file, home), null);
});
