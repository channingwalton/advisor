import { test } from "node:test";
import assert from "node:assert/strict";
import { buildResearchSystem, sessionContextPrefix, DEFAULT_PERSONA } from "./prompts.js";

test("buildResearchSystem uses the supplied persona and keeps the protected core", () => {
  const p = buildResearchSystem({ persona: "You are Bob, a terse oracle." });
  assert.match(p, /^You are Bob, a terse oracle\./);
  // Protected operating rules are always present.
  assert.match(p, /Lead with the answer; no preamble\./);
  assert.match(p, /Answer in two passes/);
  assert.match(p, /NEVER ask the user questions/);
});

test("buildResearchSystem falls back to the default persona when blank", () => {
  assert.match(buildResearchSystem({ persona: "   " }), /^You are Advisor/);
  assert.match(buildResearchSystem({}), /^You are Advisor/);
  assert.ok(buildResearchSystem({}).startsWith(DEFAULT_PERSONA));
});

test("buildResearchSystem never carries session context (that is injected per task)", () => {
  assert.doesNotMatch(buildResearchSystem({}), /Context for this session/);
});

test("sessionContextPrefix wraps the live session prompt and ends with a blank line", () => {
  const pre = sessionContextPrefix("Call with Acme about pricing.");
  assert.match(pre, /^Context for this session \(the user may update this/);
  assert.match(pre, /Call with Acme about pricing\.\n\n$/);
});

test("sessionContextPrefix is empty for blank or whitespace input", () => {
  assert.equal(sessionContextPrefix(""), "");
  assert.equal(sessionContextPrefix("   \n "), "");
});
