import { test } from "node:test";
import assert from "node:assert/strict";
import { cardOutcome, boundedPush } from "./cards.js";

test("cardOutcome returns the answer when text is present", () => {
  assert.deepEqual(cardOutcome("the answer"), { body: "the answer", state: "done" });
});

// Text streams word by word, so a turn cut short can end mid-sentence: keep
// what was written, but don't pass it off as a finished answer.
test("cardOutcome keeps a partial answer and says it stopped early", () => {
  assert.deepEqual(cardOutcome("Cedar is the datab", "timed out"), {
    body: "Cedar is the datab\n\n*Stopped early: timed out.*",
    state: "done",
  });
});

test("cardOutcome surfaces the failure reason when text is empty", () => {
  assert.deepEqual(cardOutcome("", "timed out"), { body: "failed: timed out", state: "failed" });
});

test("cardOutcome falls back to a generic message with no text and no error", () => {
  assert.deepEqual(cardOutcome(""), { body: "no answer produced", state: "failed" });
});

test("boundedPush keeps under the cap and evicts the oldest", () => {
  const q: number[] = [];
  assert.deepEqual(boundedPush(q, 1, 3), []);
  boundedPush(q, 2, 3);
  boundedPush(q, 3, 3);
  assert.deepEqual(q, [1, 2, 3]); // exactly at cap, nothing dropped
  const dropped = boundedPush(q, 4, 3);
  assert.deepEqual(dropped, [1]); // oldest evicted
  assert.deepEqual(q, [2, 3, 4]); // newest kept
});

test("boundedPush evicts as many as needed when already over cap", () => {
  const q = [1, 2, 3, 4, 5];
  const dropped = boundedPush(q, 6, 3);
  assert.deepEqual(dropped, [1, 2, 3]); // trims down to exactly max=3
  assert.deepEqual(q, [4, 5, 6]);
});
