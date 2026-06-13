import { test } from "node:test";
import assert from "node:assert/strict";
import { mergeConfig, modelArg } from "./config.js";

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
