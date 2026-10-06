import { test } from "node:test";
import assert from "node:assert/strict";
import { AutoPipeline } from "./autoPipeline.js";
import { Transcript, type Lane } from "./lanes.js";
import type { ClassifyResult, Trigger } from "./trigger.js";

/// A pipeline over fakes: a classifier the test answers by hand (each call is a
/// deferred promise), lanes the test can mark busy, and a record of research.
function harness(lanes = 1, debounceMs = 0) {
  const transcript = new Transcript();
  const windows: string[] = [];
  const coveredLists: string[][] = [];
  const pending: ((r: ClassifyResult) => void)[] = [];
  const researched: string[] = [];
  const pool: Lane[] = Array.from({ length: lanes }, (_, i) => ({
    name: `research${i}`, busy: false,
    session: { run: async () => ({ text: "" }), reset: () => {}, interrupt: async () => {} },
  }));
  const pipeline = new AutoPipeline({
    transcript,
    debounceMs,
    classify: (window, covered) => {
      windows.push(window);
      coveredLists.push(covered);
      return new Promise((resolve) => pending.push(resolve));
    },
    freeLane: () => pool.find((l) => !l.busy),
    research: async (_lane, t) => { researched.push(t.subject); },
  });
  let n = 0;
  const say = (text: string) => {
    transcript.push({ id: `u${++n}`, source: "them", text, ts: n });
    pipeline.heard();
  };
  const answer = (...subjects: string[]) =>
    pending.shift()!({ ok: true, triggers: subjects.map((subject): Trigger => ({ kind: "question", subject, query: subject })) });
  return { pipeline, say, answer, windows, coveredLists, researched, pool, pending, transcript };
}

/// Let timers (debounce 0) and promise continuations run.
const settle = () => new Promise((resolve) => setTimeout(resolve, 5));

test("#auto-off-stops-cards a classify still running when Auto cards goes off starts no card", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("What is Cedar?");
  await settle();
  assert.equal(h.windows.length, 1, "classify started");

  h.pipeline.setAuto(false);
  h.answer("Cedar");
  await settle();
  assert.deepEqual(h.researched, []);
});

test("#auto-off-stops-cards research waiting for a lane is dropped when Auto cards goes off", async () => {
  const h = harness(1);
  h.pool[0].busy = true; // every lane busy: triggers queue
  h.pipeline.start();
  h.say("What is Cedar? And who owns Birch?");
  await settle();
  h.answer("Cedar", "Birch");
  await settle();
  assert.deepEqual(h.researched, []);

  h.pipeline.setAuto(false);
  h.pool[0].busy = false;
  h.pipeline.drain(); // a lane finishing
  await settle();
  assert.deepEqual(h.researched, []);
});

test("#auto-off-stops-cards a classify waiting out the pause is cancelled when Auto cards goes off", async () => {
  const h = harness(1, 20);
  h.pipeline.start();
  h.say("What is Cedar?");
  h.pipeline.setAuto(false);
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(h.windows.length, 0);
});

test("#auto-resume-new-speech turning Auto cards back on classifies only what is said from then on", async () => {
  const h = harness();
  h.pipeline.start();
  h.pipeline.setAuto(false);
  h.say("Said while off");
  await settle();
  assert.equal(h.windows.length, 0);

  h.pipeline.setAuto(true);
  h.say("Said after");
  await settle();
  assert.equal(h.windows.length, 1);
  assert.match(h.windows[0], /Said after/);
  assert.doesNotMatch(h.windows[0], /Said while off/);
});

test("#auto-resume-new-speech a classify from before an off-and-on drops its result and keeps the skip", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("Before");
  await settle();
  h.pipeline.setAuto(false);
  h.say("While off");
  h.pipeline.setAuto(true);
  h.answer("Before"); // the old classify finishes after the toggle
  await settle();
  assert.deepEqual(h.researched, []);

  h.say("After");
  await settle();
  assert.match(h.windows[1], /After/);
  assert.doesNotMatch(h.windows[1], /While off/);
});

test("a failed classify re-feeds its window; a successful one moves past it (issue #43)", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("What is Cedar?");
  await settle();
  h.pending.shift()!({ ok: false });
  await settle();
  h.say("And Birch?");
  await settle();
  assert.match(h.windows[1], /Cedar/, "the failed window is re-fed");
  h.answer("Cedar");
  await settle();
  assert.deepEqual(h.researched, ["Cedar"]);
  h.say("Thanks");
  await settle();
  assert.doesNotMatch(h.windows[2], /Cedar/);
});

test("#auto-off-stops-cards research dropped by turning Auto cards off can come up again", async () => {
  const h = harness(1);
  h.pool[0].busy = true;
  h.pipeline.start();
  h.say("Who owns Birch?");
  await settle();
  h.answer("Birch"); // queued: the only lane is busy
  await settle();
  h.pipeline.setAuto(false);
  h.pipeline.setAuto(true);
  h.pool[0].busy = false;

  h.say("Back to Birch — who owns it?");
  await settle();
  assert.deepEqual(h.coveredLists[1], [], "the classifier isn't told Birch is covered");
  h.answer("Birch");
  await settle();
  assert.deepEqual(h.researched, ["Birch"], "never researched, so not covered");
});

test("a classify still running across a session restart neither starts cards nor moves the cursor", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("Old session line");
  await settle();
  h.pipeline.end();
  h.transcript.clear();
  h.pipeline.start();
  h.answer("Old subject"); // the old session's classify finishes late
  await settle();
  assert.deepEqual(h.researched, []);

  h.say("New session line");
  await settle();
  assert.match(h.windows[1] ?? "", /New session line/);
});

test("research dropped because the queue is full can come up again", async () => {
  const h = harness(1);
  h.pool[0].busy = true;
  h.pipeline.start();
  h.say("A long list of questions");
  await settle();
  h.answer(...Array.from({ length: 21 }, (_, i) => `Subject ${i}`)); // one over the cap
  await settle();
  h.say("Back to Subject 0");
  await settle();
  assert.ok(!h.coveredLists[1].includes("subject 0"), "the dropped oldest is not covered");
});

test("ending the session drops research still waiting for a lane", async () => {
  const h = harness(1);
  h.pool[0].busy = true;
  h.pipeline.start();
  h.say("What is Cedar?");
  await settle();
  h.answer("Cedar");
  await settle();
  h.pipeline.end();
  h.pool[0].busy = false;
  h.pipeline.drain();
  await settle();
  assert.deepEqual(h.researched, []);
});

test("after three failed classifies the window is given up on (issue #43)", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("What is Cedar?");
  for (let attempt = 0; attempt < 3; attempt++) {
    await settle();
    h.pending.shift()!({ ok: false });
    await settle();
    h.say(`line ${attempt}`); // a new line prompts the next pass
  }
  await settle();
  assert.doesNotMatch(h.windows[3], /Cedar/, "re-fed twice, then skipped");
});
