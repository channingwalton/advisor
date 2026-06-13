import { test } from "node:test";
import assert from "node:assert/strict";
import { buildResearchSystem, sessionContextPrefix, PERSONA } from "./prompts.js";

test("buildResearchSystem leads with the fixed persona and keeps the protected core", () => {
  const p = buildResearchSystem();
  assert.ok(p.startsWith(PERSONA));
  assert.match(p, /^You are Advisor/);
  // Protected operating rules are always present.
  assert.match(p, /Lead with the answer; no preamble\./);
  assert.match(p, /Answer in two passes/);
  assert.match(p, /NEVER ask the user questions/);
});

test("buildResearchSystem never carries session context (that is injected per task)", () => {
  assert.doesNotMatch(buildResearchSystem(), /Context for this session/);
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
