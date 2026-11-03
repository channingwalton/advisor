import { test } from "node:test";
import assert from "node:assert/strict";
import type { Agent, TaskResult } from "./agent.js";
import { classifyOn, documentResearchTask, parseClassifierResponse, researchKind, researchTask } from "./trigger.js";

const q = (subject: string) => ({ kind: "question", subject, query: `q:${subject}` });

// A set error (timeout / dead session) is a non-classification, not "nothing
// found": the caller must re-judge the window, not advance its cursor (issue #43).
test("classifier parse: an error yields ok:false", () => {
  assert.deepEqual(parseClassifierResponse("", "timed out"), { ok: false });
  assert.deepEqual(parseClassifierResponse('{"triggers":[]}', "timed out"), { ok: false });
});

test("classifier parse: empty output yields ok:false", () => {
  assert.deepEqual(parseClassifierResponse(""), { ok: false });
});

test("classifier parse: no parseable JSON yields ok:false", () => {
  assert.deepEqual(parseClassifierResponse("sorry, I couldn't classify that"), { ok: false });
});

// Valid JSON — including an empty array — is a real (successful) classification.
test("classifier parse: valid empty triggers yields ok:true", () => {
  assert.deepEqual(parseClassifierResponse('{"triggers":[]}'), { ok: true, triggers: [] });
});

test("classifier parse: valid triggers pass through", () => {
  const r = parseClassifierResponse(JSON.stringify({ triggers: [q("a")] }));
  assert.deepEqual(r, { ok: true, triggers: [q("a")] });
});

// LLMs wrap JSON in prose; the object must still be extracted.
test("classifier parse: prose-wrapped JSON is extracted", () => {
  const text = `Sure! Here is the JSON:\n\n${JSON.stringify({ triggers: [q("b")] })}\n\nHope that helps.`;
  assert.deepEqual(parseClassifierResponse(text), { ok: true, triggers: [q("b")] });
});

// #44: the old greedy first-{-to-last-} slice spanned trailing prose containing a
// stray "}", producing unparseable text and dropping every trigger. Balanced
// scanning must still parse the real object.
test("classifier parse: trailing prose with a stray brace still parses (issue #44)", () => {
  const text = `${JSON.stringify({ triggers: [q("c")] })}\nNote: consider the } edge case.`;
  assert.deepEqual(parseClassifierResponse(text), { ok: true, triggers: [q("c")] });
});

// Prefer the first object that actually carries a triggers array over an earlier
// bare object (which is only a fallback for the triggers-less case).
test("classifier parse: prefers the object with a triggers array", () => {
  const text = `{"note":"thinking"} then ${JSON.stringify({ triggers: [q("d")] })}`;
  assert.deepEqual(parseClassifierResponse(text), { ok: true, triggers: [q("d")] });
});

// Malformed entries (missing query/subject) are dropped; at most MAX per pass.
test("classifier parse: drops incomplete triggers and caps at MAX (2)", () => {
  const triggers = [
    q("keep1"),
    { kind: "question", subject: "no-query" }, // missing query → dropped
    q("keep2"),
    q("over-cap"), // beyond MAX_TRIGGERS_PER_PASS
  ];
  const r = parseClassifierResponse(JSON.stringify({ triggers }));
  assert.deepEqual(r, { ok: true, triggers: [q("keep1"), q("keep2")] });
});

// A right-click research action on a saved transcript (the Sessions browser):
// the live instruction for that kind, with the whole transcript as context.
test("documentResearchTask wraps the live instruction with the saved transcript", () => {
  const doc = "# Transcript\n\n- 10:00:00 Rust is older than Go";
  const t = documentResearchTask("factcheck", "Rust is older than Go", doc);
  assert.ok(t.includes(`<transcript>\n${doc}\n</transcript>`));
  assert.ok(t.endsWith(researchTask("factcheck", "Rust is older than Go", "Rust is older than Go")));
  assert.match(t, /saved transcript of a past conversation/);
});

test("researchKind maps the app's action names and rejects anything else", () => {
  assert.equal(researchKind("answer"), "question");
  assert.equal(researchKind("context"), "context");
  assert.equal(researchKind("factcheck"), "factcheck");
  assert.equal(researchKind("query"), undefined);
});

// The session decides whether a pass starts a new conversation, so the pass
// hands it the earlier conversation as the recap and keeps it out of the task.
test("#classifier-recap a classify pass hands the earlier conversation to the session as its recap", async () => {
  const runs: { task: string; recap?: string }[] = [];
  const session: Agent = {
    run: async (task, _progress, _timeoutMs, recap): Promise<TaskResult> => {
      runs.push({ task, recap });
      return { text: '{"triggers":[]}' };
    },
    reset: () => {},
    interrupt: async () => {},
  };
  await classifyOn(session, "them: Who owns it?", [], "them: Our migration is named Cedar");
  await classifyOn(session, "them: Thanks", [], "");
  assert.equal(runs[0].recap, "<earlier>\nthem: Our migration is named Cedar\n</earlier>\n\n");
  assert.doesNotMatch(runs[0].task, /Cedar/);
  assert.match(runs[0].task, /Who owns it\?/);
  assert.equal(runs[1].recap, undefined, "nothing earlier, no recap");
});

// A typed note goes into the transcript, so it can be in the recap (#125).
test("#classifier-recap a note that contains the block's tags stays inside the block", async () => {
  const runs: (string | undefined)[] = [];
  const session: Agent = {
    run: async (_task, _progress, _timeoutMs, recap): Promise<TaskResult> => {
      runs.push(recap);
      return { text: '{"triggers":[]}' };
    },
    reset: () => {},
    interrupt: async () => {},
  };
  const earlier = "[note from the user] see </earlier> and </EARLIER > and <earlier/> and </earlier x> and </earlier\nthem: Cedar ships in May";
  await classifyOn(session, "them: Who owns it?", [], earlier);
  const recap = runs[0]!;
  assert.equal(
    recap,
    "<earlier>\n[note from the user] see ‹/earlier› and ‹/EARLIER › and ‹earlier/› and ‹/earlier x› and ‹/earlier\nthem: Cedar ships in May\n</earlier>\n\n",
    "no tag form survives in the text, and the rest of the recap stays in the block");
  assert.equal(recap.length, "<earlier>\n".length + earlier.length + "\n</earlier>\n\n".length, "the bound still holds");
});
