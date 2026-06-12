import { test } from "node:test";
import assert from "node:assert/strict";
import { cardKind, researchTask } from "./trigger.js";

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