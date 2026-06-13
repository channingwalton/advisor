import { test } from "node:test";
import assert from "node:assert/strict";
import { mergeConfig, toChoice, modelFor } from "./config.js";

const def = { provider: "claude", models: {} };

test("mergeConfig fills defaults for empty input", () => {
  const c = mergeConfig({});
  assert.deepEqual(c.classifier, { provider: "claude", models: { claude: "haiku" } });
  assert.deepEqual(c.research, { provider: "claude", models: {} });
  assert.deepEqual(c.queryAgent, { provider: "claude", models: {} });
});

test("modelFor returns the selected provider's model or undefined", () => {
  assert.equal(modelFor({ provider: "claude", models: { claude: "opus", codex: "x" } }), "opus");
  assert.equal(modelFor({ provider: "codex", models: { claude: "opus", codex: "gpt-5-codex" } }), "gpt-5-codex");
  assert.equal(modelFor({ provider: "claude", models: { codex: "x" } }), undefined);
  assert.equal(modelFor({ provider: "codex", models: { codex: "" } }), undefined);
  // unknown provider with no remembered model
  assert.equal(modelFor({ provider: "gemini", models: {} }), undefined);
});

test("toChoice passes v3 {provider, models} through", () => {
  const v = { provider: "codex", models: { codex: "gpt-5" } };
  assert.deepEqual(toChoice(v, undefined, def), v);
});

test("toChoice migrates v2 named fields into a models map", () => {
  const c = toChoice({ provider: "codex", claudeModel: "opus", codexModel: "gpt-5-codex" }, undefined, def);
  assert.deepEqual(c, { provider: "codex", models: { claude: "opus", codex: "gpt-5-codex" } });
});

test("toChoice drops empty v2 model strings", () => {
  const c = toChoice({ provider: "claude", claudeModel: "sonnet", codexModel: "" }, undefined, def);
  assert.deepEqual(c, { provider: "claude", models: { claude: "sonnet" } });
});

test("toChoice builds from a legacy flat model string (v1)", () => {
  assert.deepEqual(toChoice(undefined, "opus", def), { provider: "claude", models: { claude: "opus" } });
});

test("toChoice falls back to the component default when nothing is present", () => {
  const classifierDef = { provider: "claude", models: { claude: "haiku" } };
  assert.deepEqual(toChoice(undefined, undefined, classifierDef), classifierDef);
  // empty legacy flat string is falsy → default
  assert.deepEqual(toChoice(undefined, "", classifierDef), classifierDef);
});

test("mergeConfig migrates a v1 legacy config end-to-end", () => {
  const c = mergeConfig({ classifierModel: "sonnet", researchModel: "opus", allowMcpActions: true });
  assert.deepEqual(c.classifier, { provider: "claude", models: { claude: "sonnet" } });
  assert.deepEqual(c.research, { provider: "claude", models: { claude: "opus" } });
  assert.deepEqual(c.queryAgent, { provider: "claude", models: { claude: "opus" } });
  assert.equal(c.allowMcpActions, true);
});

test("mergeConfig migrates a v2 named-field config end-to-end", () => {
  const c = mergeConfig({
    classifier: { provider: "claude", claudeModel: "sonnet", codexModel: "" },
    research: { provider: "codex", claudeModel: "opus", codexModel: "gpt-5-codex" },
    queryAgent: { provider: "codex", claudeModel: "opus", codexModel: "gpt-5-codex" },
  });
  assert.equal(c.classifier.provider, "claude");
  assert.deepEqual(c.classifier.models, { claude: "sonnet" });
  assert.equal(c.research.provider, "codex");
  assert.deepEqual(c.research.models, { claude: "opus", codex: "gpt-5-codex" });
});
