import { test } from "node:test";
import assert from "node:assert/strict";
import { cardKind, replyTask, researchTask } from "./trigger.js";

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