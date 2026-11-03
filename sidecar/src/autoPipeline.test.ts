import { test } from "node:test";
import assert from "node:assert/strict";
import { AutoPipeline, CLASSIFIER_RECAP_CHARS } from "./autoPipeline.js";
import { Transcript, type Lane } from "./lanes.js";
import type { ClassifyResult, Trigger } from "./trigger.js";

/// A pipeline over fakes: a classifier the test answers by hand (each call is a
/// deferred promise), lanes the test can mark busy, and a record of research.
function harness(lanes = 1, debounceMs = 0) {
  const transcript = new Transcript();
  const windows: string[] = [];
  const coveredLists: string[][] = [];
  /// The conversation before each window, as offered for a recap.
  const earliers: string[] = [];
  const pending: ((r: ClassifyResult) => void)[] = [];
  const researched: string[] = [];
  /// Each card's "first text sent" hook, in dispatch order.
  const cardTexts: (() => void)[] = [];
  const logs: string[] = [];
  let clock = 0;
  const pool: Lane[] = Array.from({ length: lanes }, (_, i) => ({
    name: `research${i}`, busy: false,
    session: { run: async () => ({ text: "" }), reset: () => {}, interrupt: async () => {} },
  }));
  const pipeline = new AutoPipeline({
    transcript,
    debounceMs,
    classify: (window, covered, earlier) => {
      windows.push(window);
      coveredLists.push(covered);
      earliers.push(earlier);
      return new Promise((resolve) => pending.push(resolve));
    },
    freeLane: () => pool.find((l) => !l.busy),
    research: async (_lane, t, textSent) => {
      researched.push(t.subject);
      cardTexts.push(textSent);
    },
    log: (line) => logs.push(line),
    now: () => clock,
  });
  let n = 0;
  const say = (text: string) => {
    transcript.push({ id: `u${++n}`, source: "them", text, ts: n });
    pipeline.heard();
  };
  const answer = (...subjects: string[]) =>
    pending.shift()!({ ok: true, triggers: subjects.map((subject): Trigger => ({ kind: "question", subject, query: subject })) });
  const tick = (ms: number) => { clock += ms; };
  return { pipeline, say, answer, windows, coveredLists, earliers, researched, cardTexts, pool, pending, transcript, logs, tick };
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

test("the classify log says how long after the last line heard the decision came", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("What is Cedar?"); // t=0
  h.tick(1000);
  h.say("Who owns it?"); // t=1000, the last line of the window
  h.tick(1500); // the pause before classifying
  await settle(); // classify starts at t=2500
  h.tick(900);
  h.answer(); // decided at t=3400
  await settle();
  assert.ok(
    h.logs.includes("classify 900ms → 0 trigger(s), decided 2400ms after the last line"),
    h.logs.join("\n"),
  );
});

test("a line heard while a classify runs is timed from when it was heard, not from its re-run", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("What is Cedar?");
  await settle(); // first classify starts at t=0
  h.tick(1000);
  h.say("Who owns it?"); // t=1000, waits for the first classify
  await settle();
  h.tick(2000);
  h.answer(); // t=3000: the re-run classifies "Who owns it?"
  await settle();
  h.tick(500);
  h.answer(); // decided at t=3500
  await settle();
  assert.ok(
    h.logs.includes("classify 500ms → 0 trigger(s), decided 2500ms after the last line"),
    h.logs.join("\n"),
  );
});

test("a card's log line says how long after the last line it appeared and its text began", async () => {
  const h = harness(1);
  h.pool[0].busy = true; // the card waits for a lane
  h.pipeline.start();
  h.say("What is Cedar?"); // t=0
  await settle();
  h.tick(2000);
  h.answer("Cedar"); // decided at t=2000, queued
  await settle();
  h.tick(1000);
  h.pool[0].busy = false;
  h.pipeline.drain(); // the card appears at t=3000
  await settle();
  h.tick(4000);
  h.cardTexts[0](); // its first text, at t=7000
  assert.deepEqual(
    h.logs.filter((l) => l.startsWith("card ")),
    ['card "Cedar" shown 3000ms, text 7000ms after the last line'],
  );
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

test("#classifier-recap each pass offers the conversation before its window, for a classifier that starts again", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("Our migration is named Cedar");
  await settle();
  assert.equal(h.earliers[0], "", "nothing came before the first window");
  h.answer();
  await settle();
  h.say("Who owns it?");
  await settle();
  assert.doesNotMatch(h.windows[1], /Cedar/, "a judged line is not judged again");
  assert.equal(h.earliers[1], "them: Our migration is named Cedar");
});

test("#classifier-recap a failed window is re-fed as new lines, not as the earlier conversation", async () => {
  const h = harness();
  h.pipeline.start();
  h.say("Our migration is named Cedar");
  await settle();
  h.answer();
  await settle();
  h.say("Who owns it?");
  await settle();
  h.pending.shift()!({ ok: false });
  await settle();
  h.say("And when does it ship?");
  await settle();
  assert.match(h.windows[2], /Who owns it\? And when does it ship\?/);
  assert.equal(h.earliers[2], "them: Our migration is named Cedar");
});

test("#classifier-recap the earlier conversation is bounded to its most recent lines", async () => {
  const h = harness();
  h.pipeline.start();
  const line = "x".repeat(990);
  for (let i = 0; i < 20; i++) h.transcript.push({ id: `old${i}`, source: i % 2 ? "me" : "them", text: `line${i} ${line}`, ts: i });
  h.say("First window");
  await settle();
  h.answer();
  await settle();
  h.say("Second window");
  await settle();
  const earlier = h.earliers[1];
  assert.match(earlier, /First window/, "the newest line is kept");
  assert.doesNotMatch(earlier, /line0 /, "the oldest line is left out");
  // The labels and line breaks count too (#125), and the cut is at a line.
  assert.ok(earlier.length <= CLASSIFIER_RECAP_CHARS, `${earlier.length} chars`);
  assert.ok(earlier.length > CLASSIFIER_RECAP_CHARS - 1_000, `${earlier.length} chars: no more than one line is left out to fit`);
  for (const l of earlier.split("\n")) assert.match(l, /^(them|me): (line\d+ x{990}|First window)$/);
});

test("#classifier-recap many short lines and speaker changes stay within the bound, labels included", async () => {
  const h = harness();
  h.pipeline.start();
  // Each line is short beside its label, so a count of the speech alone let the recap pass its bound by far.
  for (let i = 0; i < 2_000; i++) h.transcript.push({ id: `old${i}`, source: i % 2 ? "me" : "them", text: "ok", ts: i });
  h.say("First window");
  await settle();
  h.answer();
  await settle();
  h.say("Second window");
  await settle();
  const earlier = h.earliers[1];
  assert.ok(earlier.length <= CLASSIFIER_RECAP_CHARS, `${earlier.length} chars`);
  assert.ok(earlier.length > CLASSIFIER_RECAP_CHARS - 20, `${earlier.length} chars`);
  assert.match(earlier, /\nthem: First window$/);
  assert.match(earlier, /^(them|me): ok\n/, "the cut is at a line");
});

test("#classifier-recap lines of one speaker merge into one block within the bound", async () => {
  const h = harness();
  h.pipeline.start();
  for (let i = 0; i < 3_000; i++) h.transcript.push({ id: `old${i}`, source: "them", text: "ok", ts: i });
  h.say("First window");
  await settle();
  h.answer();
  await settle();
  h.say("Second window");
  await settle();
  const earlier = h.earliers[1];
  assert.match(earlier, /^them: ok ok .* ok First window$/);
  assert.ok(earlier.length <= CLASSIFIER_RECAP_CHARS, `${earlier.length} chars`);
  assert.ok(earlier.length > CLASSIFIER_RECAP_CHARS - 3, `${earlier.length} chars`);
});

test("#classifier-recap a single line longer than the bound keeps its end", async () => {
  const h = harness();
  h.pipeline.start();
  h.transcript.push({ id: "n1", source: "note", text: `start ${"x".repeat(CLASSIFIER_RECAP_CHARS)} end`, ts: 0 });
  h.pipeline.heard();
  await settle();
  h.answer();
  await settle();
  h.say("Next");
  await settle();
  assert.match(h.earliers[1], /^\[note from the user\] …x+ end$/);
  assert.equal(h.earliers[1].length, CLASSIFIER_RECAP_CHARS, "the label and the ellipsis count too (#125)");
});

test("#trigger-subject-any-script a subject in any script becomes a card, once", async () => {
  const h = harness(2);
  h.pipeline.start();
  h.say("東京とΕλλάδα");
  await settle();
  h.answer("東京", "Ελλάδα");
  await settle();
  assert.deepEqual([...h.researched].sort(), ["Ελλάδα", "東京"].sort());

  // Covered as itself: not raised twice, and named to the classifier as covered.
  h.say("また東京");
  await settle();
  assert.ok(h.coveredLists[1].includes("東京"), JSON.stringify(h.coveredLists[1]));
  h.answer("東京");
  await settle();
  assert.equal(h.researched.filter((s) => s === "東京").length, 1);
});

test("#trigger-subject-any-script accented subjects don't collide with unaccented prefixes", async () => {
  const h = harness(2);
  h.pipeline.start();
  h.say("Café and caf");
  await settle();
  h.answer("café", "caf");
  await settle();
  assert.deepEqual([...h.researched].sort(), ["caf", "café"]);
});

test("#trigger-subject-any-script case and spacing variants of one subject make one card", async () => {
  for (const [first, again] of [
    ["Москва", "МОСКВА"], // case in another alphabet
    ["İstanbul", "Istanbul"], // Turkish dotted capital I
    ["New\tYork", "New  York"], // any whitespace is one space
    ["東京　タワー", "東京 タワー"], // the ideographic space too
  ]) {
    const h = harness(2);
    h.pipeline.start();
    h.say("first");
    await settle();
    h.answer(first);
    await settle();
    h.say("again");
    await settle();
    h.answer(again);
    await settle();
    assert.deepEqual(h.researched, [first], `${first} / ${again}`);
  }
});

test("#trigger-subject-any-script words that differ only by a mark stay distinct", async () => {
  // A wrong merge silently loses a card; a missed one only duplicates a card.
  for (const pair of [
    ["がっこう", "かっこう"], // school / cuckoo (dakuten)
    ["año", "ano"], // year / anus
    ["мой", "мои"], // my (sing.) / my (pl.)
    ["Hà Nội", "Hà Nổi"], // Vietnamese tones
    ["Maße", "Masse"], // measurements / mass: ß is not ss here
  ]) {
    const h = harness(2);
    h.pipeline.start();
    h.say("two subjects");
    await settle();
    h.answer(...pair);
    await settle();
    assert.deepEqual([...h.researched].sort(), [...pair].sort(), pair.join(" / "));
  }
});

// The research pool sheds an excess lane the moment its card finishes (LanePool
// .release), so the pipeline hands a finished lane back through `releaseLane`
// when the deps provide it, rather than only clearing `busy` itself.
test("#lane-pool a finished research lane is handed back through releaseLane", async () => {
  const transcript = new Transcript();
  const lane: Lane = {
    name: "research0", busy: false,
    session: { run: async () => ({ text: "" }), reset: () => {}, interrupt: async () => {} },
  };
  const released: string[] = [];
  const pipeline = new AutoPipeline({
    transcript,
    debounceMs: 0,
    classify: async () => ({ ok: true, triggers: [{ kind: "question", subject: "Cedar", query: "Cedar" }] }),
    freeLane: () => (lane.busy ? undefined : lane),
    releaseLane: (l) => { released.push(l.name); l.busy = false; },
    research: async () => {},
  });
  pipeline.start();
  transcript.push({ id: "u1", source: "them", text: "What is Cedar?", ts: 1 });
  pipeline.heard();
  await settle();
  assert.deepEqual(released, ["research0"]);
  assert.equal(lane.busy, false);
});
