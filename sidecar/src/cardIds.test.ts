import assert from "node:assert/strict";
import test from "node:test";
import { ProcessCardIDs } from "./cardIds.js";

test("first card ids differ across sidecar process incarnations", () => {
  const firstProcess = new ProcessCardIDs();
  const restartedProcess = new ProcessCardIDs();

  assert.notEqual(firstProcess.next(), restartedProcess.next());
});

test("card ids are monotonic within one sidecar process", () => {
  const ids = new ProcessCardIDs("process-a");

  assert.equal(ids.next(), "process-a:c1");
  assert.equal(ids.next(), "process-a:c2");
});
