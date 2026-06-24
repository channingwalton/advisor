import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildResearchSystem,
  sessionContextPrefix,
  summaryTask,
  transcriptLine,
  PERSONA,
} from "./prompts.js";

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

test("transcriptLine renders speech as `source: text`", () => {
  assert.equal(transcriptLine("me", "hello"), "me: hello");
  assert.equal(transcriptLine("them", "hi there"), "them: hi there");
});

test("transcriptLine labels an editorial note so the agent reads it as user context, not speech", () => {
  const line = transcriptLine("note", "they mean the Q1 Postgres migration");
  assert.match(line, /note from the user/i);
  assert.ok(line.includes("they mean the Q1 Postgres migration"));
  // Not formatted as a spoken line.
  assert.doesNotMatch(line, /^note: /);
});

test("summaryTask embeds the transcript verbatim and asks for a faithful summary", () => {
  const t = summaryTask("me: hello\nthem: hi there");
  assert.match(t, /<transcript>\nme: hello\nthem: hi there\n<\/transcript>/);
  assert.match(t, /[Ss]ummari[sz]e/);
  // No-invention guard, so a summary can't hallucinate beyond the transcript.
  assert.match(t, /do not invent|faithful/i);
});
