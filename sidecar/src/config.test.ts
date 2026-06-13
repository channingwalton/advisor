import { test } from "node:test";
import assert from "node:assert/strict";
import { mergeConfig, modelArg } from "./config.js";
import { DEFAULT_PERSONA } from "./prompts.js";

test("mergeConfig defaults personaPrompt to the default persona and overrides it", () => {
  assert.equal(mergeConfig({}).personaPrompt, DEFAULT_PERSONA);
  assert.equal(mergeConfig({ personaPrompt: "You are Bob." }).personaPrompt, "You are Bob.");
});

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
