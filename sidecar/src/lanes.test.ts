import { test } from "node:test";
import assert from "node:assert/strict";
import type { TaskResult } from "./agent.js";
import type { Outbound } from "./protocol.js";
import { cardLaneOptions, LanePool, runCard, Transcript, type Lane, type RunCardDeps } from "./lanes.js";
import { mergeConfig } from "./config.js";

/// A session that records each prompt and answers from a script; `reset()` is
/// counted so a test can see the lane recycle.
function scriptedLane(answers: TaskResult[]): Lane & { prompts: string[]; resets: number } {
  const lane = {
    name: "research0",
    busy: false,
    prompts: [] as string[],
    resets: 0,
    session: {
      run: async (task: string): Promise<TaskResult> => {
        lane.prompts.push(task);
        return answers.shift() ?? { text: "ok" };
      },
      reset: () => { lane.resets += 1; },
      interrupt: async () => {},
    },
  };
  return lane;
}

function deps(transcript: Transcript): RunCardDeps & { sent: Outbound[] } {
  let n = 0;
  const sent: Outbound[] = [];
  return {
    transcript,
    nextCardId: () => `c${++n}`,
    sessionContext: () => "",
    cancelledCards: new Set<string>(),
    send: (m) => sent.push(m),
    sent,
  };
}

const say = (t: Transcript, id: string, text: string) => t.push({ id, source: "them", text, ts: 0 });

test("#context-lane-recycle a lane restarted after a failed card is sent the whole conversation again", async () => {
  const transcript = new Transcript();
  const lane = scriptedLane([{ text: "", error: "timed out" }, { text: "Priya" }]);
  const d = deps(transcript);

  say(transcript, "u1", "Our migration is named Cedar");
  await runCard(lane, "answer", "Cedar", "Answer: what is Cedar?", "u1", d);
  assert.equal(lane.resets, 1, "the failed card recycles the lane");

  say(transcript, "u2", "Who owns it?");
  await runCard(lane, "answer", "owner", "Answer: who owns it?", "u2", d);
  // The fresh session never saw u1, so the prompt must carry it again.
  assert.match(lane.prompts[1], /Cedar/);
  assert.match(lane.prompts[1], /Who owns it\?/);
});

test("#context-lane-recycle a warm lane is sent only what it hasn't seen", async () => {
  const transcript = new Transcript();
  const lane = scriptedLane([{ text: "a project" }, { text: "Priya" }]);
  const d = deps(transcript);

  say(transcript, "u1", "Our migration is named Cedar");
  await runCard(lane, "answer", "Cedar", "Answer: what is Cedar?", "u1", d);
  say(transcript, "u2", "Who owns it?");
  await runCard(lane, "answer", "owner", "Answer: who owns it?", "u2", d);

  assert.equal(lane.resets, 0);
  assert.doesNotMatch(lane.prompts[1], /Cedar/);
  assert.match(lane.prompts[1], /Who owns it\?/);
});

// Every card lane (research, query, reply, document, summary) is built from
// these options, so the effort preference must ride them.
test("card lane options carry the configured model, effort and connector setting", () => {
  const o = cardLaneOptions(mergeConfig({ model: "opus", effort: "low", allowMcpActions: true }), "research0");
  assert.equal(o.name, "research0");
  assert.equal(o.model, "opus");
  assert.equal(o.effort, "low");
  assert.equal(o.allowMcpActions, true);
});

test("card lane options inherit the user's effort when none is configured", () => {
  assert.equal(cardLaneOptions(mergeConfig({}), "query").effort, undefined);
});

// The research pool's size can change mid-session. A shrink must not leave the
// excess lanes' sessions (and their CLI subprocesses) alive until the next
// session start (code review 2026-10-17).
function pool(max: number): {
  pool: LanePool; made: string[]; shed: string[]; lanes: Map<string, ReturnType<typeof scriptedLane>>;
} {
  const made: string[] = [];
  const shed: string[] = [];
  const lanes = new Map<string, ReturnType<typeof scriptedLane>>();
  const p = new LanePool((name) => {
    made.push(name);
    const lane = scriptedLane([]);
    lane.name = name;
    lanes.set(name, lane);
    return lane;
  }, max, (lane) => shed.push(lane.name));
  return { pool: p, made, shed, lanes };
}

test("#lane-pool grows lazily to its size and hands out idle lanes within it", () => {
  const { pool: p, made } = pool(2);
  assert.deepEqual(made, []);
  const a = p.free();
  assert.equal(a?.name, "research0");
  assert.deepEqual(made, ["research0", "research1"]);
  a!.busy = true;
  assert.equal(p.free()?.name, "research1");
  p.all[1].busy = true;
  assert.equal(p.free(), undefined);
});

test("#lane-pool shrinking resets idle excess lanes at once, and sheds their cursors", () => {
  const { pool: p, lanes, shed } = pool(3);
  p.free();
  p.resize(1);
  assert.deepEqual(p.all.map((l) => l.name), ["research0"]);
  assert.equal(lanes.get("research1")!.resets, 1);
  assert.equal(lanes.get("research2")!.resets, 1);
  assert.equal(lanes.get("research0")!.resets, 0);
  assert.deepEqual(shed.sort(), ["research1", "research2"]);
});

test("#lane-pool a busy excess lane finishes its card, is never dispatched to again, then goes at release", () => {
  const { pool: p, lanes, shed } = pool(2);
  p.free();
  const second = lanes.get("research1")!;
  second.busy = true;
  p.resize(1);
  assert.equal(second.resets, 0, "mid-card: kept");
  assert.deepEqual(p.all.map((l) => l.name), ["research0", "research1"]);
  lanes.get("research0")!.busy = true;
  assert.equal(p.free(), undefined, "an excess lane is not a free lane");
  p.release(second); // its card finished — nothing else need happen
  assert.equal(second.busy, false);
  assert.equal(second.resets, 1);
  assert.deepEqual(shed, ["research1"]);
  assert.deepEqual(p.all.map((l) => l.name), ["research0"]);
  p.release(lanes.get("research0")!);
  assert.equal(lanes.get("research0")!.resets, 0, "a lane within the size stays warm");
});

test("#lane-pool a grow after a shrink never mints a name still in use", () => {
  // Names key the transcript cursors: two lanes called research2 would share one.
  const { pool: p, lanes } = pool(3);
  p.free();
  lanes.get("research2")!.busy = true;
  p.resize(1); // research1 idle → shed; research2 mid-card → kept past the size
  assert.deepEqual(p.all.map((l) => l.name), ["research0", "research2"]);
  p.resize(3);
  p.all.forEach((l) => (l.busy = true));
  p.free(); // grows by one
  const names = p.all.map((l) => l.name);
  assert.equal(new Set(names).size, names.length, names.join(","));
  assert.ok(names.includes("research1"), names.join(","));
});

test("#lane-pool releasing a lane the pool has already dropped only marks it idle", () => {
  const { pool: p, lanes } = pool(1);
  p.free();
  const old = lanes.get("research0")!;
  old.busy = true;
  p.reset(); // a session start mid-card: the old lane is dropped and rebuilt
  const fresh = p.all[0];
  assert.notEqual(fresh, old);
  p.release(old);
  assert.equal(old.busy, false);
  assert.deepEqual(p.all, [fresh], "the dropped lane's release leaves the pool alone");
});

test("#lane-pool growing again makes fresh lanes", () => {
  const { pool: p, made } = pool(1);
  p.free();
  p.resize(2);
  assert.deepEqual(made, ["research0"]);
  p.all[0].busy = true;
  assert.equal(p.free()?.name, "research1");
  assert.deepEqual(made, ["research0", "research1"]);
});

test("#lane-pool reset drops every session and rebuilds to size", () => {
  const { pool: p, lanes, made, shed } = pool(2);
  p.free();
  const [old0, old1] = [lanes.get("research0")!, lanes.get("research1")!]; // the rebuilt lanes reuse the names
  p.reset();
  assert.equal(old0.resets, 1);
  assert.equal(old1.resets, 1);
  assert.deepEqual(shed.sort(), ["research0", "research1"]);
  assert.deepEqual(made, ["research0", "research1", "research0", "research1"]);
  assert.equal(p.all.length, 2);
});
