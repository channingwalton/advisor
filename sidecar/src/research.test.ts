import { test } from "node:test";
import assert from "node:assert/strict";
import { cardKind, parseClassifierResponse, replyTask, researchTask } from "./trigger.js";

test("cardKind maps question to answer, others unchanged", () => {
  assert.equal(cardKind("question"), "answer");
  assert.equal(cardKind("context"), "context");
  assert.equal(cardKind("factcheck"), "factcheck");
});

test("researchTask question template asks the question", () => {
  assert.equal(
    researchTask("question", "subject", "what is X"),
    "Answer this question from the conversation: what is X"
  );
});

test("researchTask factcheck template demands verdict first", () => {
  const task = researchTask("factcheck", "the claim", "the claim");
  assert.match(task, /Fact-check this claim from the conversation: "the claim"/);
  assert.match(task, /verdict first/);
});

test("researchTask context template uses the subject", () => {
  assert.equal(
    researchTask("context", "Project Foo", "they mentioned Project Foo"),
    'Give brief, useful background on "Project Foo" as it relates to the conversation: they mentioned Project Foo'
  );
});

test("replyTask embeds card body, title, follow-up and transcript", () => {
  const task = replyTask(
    "answer",
    "GDP of France",
    "France's GDP is about $3.1tn (2023).",
    "what about per capita?",
    "them: how rich is France\nme: not sure"
  );
  assert.match(task, /titled "GDP of France"/);
  assert.match(task, /France's GDP is about \$3\.1tn/);
  assert.match(task, /<followup>\nwhat about per capita\?\n<\/followup>/);
  assert.match(task, /<transcript>\nthem: how rich is France\nme: not sure\n<\/transcript>/);
  assert.match(task, /Answer the follow-up concisely/);
});

test("replyTask omits the transcript block when there is no transcript", () => {
  const task = replyTask("context", "Foo", "Foo is a thing.", "tell me more", "   ");
  assert.doesNotMatch(task, /<transcript>/);
  assert.match(task, /<followup>\ntell me more\n<\/followup>/);
});

// parseClassifierResponse is the root of issue #43: a genuine "found nothing"
// (ok:true, empty triggers) must be distinguishable from a failure to classify
// (ok:false), so main.ts only advances the classifier cursor on success.

test("parseClassifierResponse: valid JSON with no triggers is a success, not a failure", () => {
  const r = parseClassifierResponse('{"triggers":[]}');
  assert.deepEqual(r, { ok: true, triggers: [] });
});

test("parseClassifierResponse: valid JSON with triggers is a success", () => {
  const r = parseClassifierResponse(
    '{"triggers":[{"kind":"question","subject":"GDP","query":"what is France GDP"}]}'
  );
  assert.deepEqual(r, {
    ok: true,
    triggers: [{ kind: "question", subject: "GDP", query: "what is France GDP" }],
  });
});

test("parseClassifierResponse: extracts JSON embedded in surrounding prose", () => {
  const r = parseClassifierResponse('Here you go: {"triggers":[]} — done');
  assert.deepEqual(r, { ok: true, triggers: [] });
});

test("parseClassifierResponse: drops triggers missing required fields, caps at MAX_TRIGGERS_PER_PASS", () => {
  const r = parseClassifierResponse(
    '{"triggers":[' +
      '{"kind":"question","subject":"a","query":"qa"},' +
      '{"kind":"context"},' + // missing subject/query — dropped
      '{"kind":"context","subject":"b","query":"qb"},' +
      '{"kind":"factcheck","subject":"c","query":"qc"}' + // 3rd valid — over the cap of 2
      "]}"
  );
  assert.equal(r.ok, true);
  assert.deepEqual(r.ok && r.triggers, [
    { kind: "question", subject: "a", query: "qa" },
    { kind: "context", subject: "b", query: "qb" },
  ]);
});

test("parseClassifierResponse: a run error (timeout / dead session) is a failure", () => {
  assert.deepEqual(parseClassifierResponse("", "timed out"), { ok: false });
  // error wins even if partial text is present
  assert.deepEqual(parseClassifierResponse('{"triggers":[]}', "timed out"), { ok: false });
});

test("parseClassifierResponse: empty output is a failure (re-feed, don't drop)", () => {
  assert.deepEqual(parseClassifierResponse(""), { ok: false });
});

test("parseClassifierResponse: output with no JSON object is a failure", () => {
  assert.deepEqual(parseClassifierResponse("sorry, I can't do that"), { ok: false });
});

test("parseClassifierResponse: unparseable JSON is a failure", () => {
  assert.deepEqual(parseClassifierResponse('{"triggers":[oops]}'), { ok: false });
});

// Issue #44: greedy first-`{`-to-last-`}` extraction spanned across trailing
// content and dropped every trigger. Extraction now takes the first balanced
// JSON object, respecting string literals so a brace inside a value can't
// truncate it early.

test("parseClassifierResponse: prose prefix + valid object + trailing junk object still extracts triggers (issue #44 repro)", () => {
  const r = parseClassifierResponse(
    'sure! {"triggers":[{"kind":"question","subject":"x","query":"y"}]} and also {"junk":1}'
  );
  assert.deepEqual(r, {
    ok: true,
    triggers: [{ kind: "question", subject: "x", query: "y" }],
  });
});

test("parseClassifierResponse: a } inside a string value does not truncate the object early", () => {
  const r = parseClassifierResponse(
    '{"triggers":[{"kind":"question","subject":"regex","query":"what does the } in a}b glob mean"}]}'
  );
  assert.deepEqual(r, {
    ok: true,
    triggers: [{ kind: "question", subject: "regex", query: "what does the } in a}b glob mean" }],
  });
});

test("parseClassifierResponse: an escaped quote inside a string value is handled", () => {
  const r = parseClassifierResponse(
    '{"triggers":[{"kind":"context","subject":"quote","query":"they said \\"} done\\" out loud"}]}'
  );
  assert.deepEqual(r, {
    ok: true,
    triggers: [{ kind: "context", subject: "quote", query: 'they said "} done" out loud' }],
  });
});

test("parseClassifierResponse: prose-wrapped single object with triggers", () => {
  const r = parseClassifierResponse(
    'Here is the JSON you asked for:\n{"triggers":[{"kind":"factcheck","subject":"gdp","query":"is France GDP $3tn"}]}\nHope that helps.'
  );
  assert.deepEqual(r, {
    ok: true,
    triggers: [{ kind: "factcheck", subject: "gdp", query: "is France GDP $3tn" }],
  });
});

test("parseClassifierResponse: a leading incomplete { fragment before the real object is skipped", () => {
  const r = parseClassifierResponse(
    '{ oops truncated {"triggers":[{"kind":"question","subject":"x","query":"y"}]}'
  );
  assert.deepEqual(r, {
    ok: true,
    triggers: [{ kind: "question", subject: "x", query: "y" }],
  });
});

test("parseClassifierResponse: a junk object before the triggers object is skipped in favour of the triggers object", () => {
  const r = parseClassifierResponse(
    'per rule {"max":2} the result is {"triggers":[{"kind":"context","subject":"a","query":"qa"}]}'
  );
  assert.deepEqual(r, {
    ok: true,
    triggers: [{ kind: "context", subject: "a", query: "qa" }],
  });
});

test("parseClassifierResponse: a parseable object without a triggers array is a success with no triggers", () => {
  assert.deepEqual(parseClassifierResponse('{"junk":1}'), { ok: true, triggers: [] });
});
test("replyTask for a saved session describes a saved note, not a live conversation", () => {
  const task = replyTask("context", "Foo", "Foo is a thing.", "tell me more", "# Transcript\n- a", { saved: true });
  assert.ok(!task.includes("live conversation"));
  assert.ok(!task.includes("Recent conversation transcript"));
  assert.match(task, /saved/);
  assert.ok(task.includes("<transcript>\n# Transcript\n- a\n</transcript>"));
});
