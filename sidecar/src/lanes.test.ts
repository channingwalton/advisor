import { test } from "node:test";
import assert from "node:assert/strict";
import type { TaskResult } from "./agent.js";
import type { Outbound } from "./protocol.js";
import { cardLaneOptions, LanePool, LiveSession, QueryLanes, runCard, Transcript, type Lane, type RunCardDeps } from "./lanes.js";
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

test("runCard reports a card's first text once, as it is sent", async () => {
  const t = new Transcript();
  const lane = scriptedLane([]);
  lane.session.run = async (_task, progress) => {
    progress?.onText?.("Cedar is");
    progress?.onText?.("Cedar is the billing rewrite.");
    return { text: "Cedar is the billing rewrite." };
  };
  const d = deps(t);
  let texts = 0;
  let sentBefore = -1;
  await runCard(lane, "answer", "Cedar", "Answer: what is Cedar?", "u1", d, () => {
    texts += 1;
    sentBefore = d.sent.length;
  });
  assert.equal(texts, 1);
  assert.equal(sentBefore, 1, "reported as the first text frame goes out, after the pending card");
});

test("runCard reports no text for a card that fails without any", async () => {
  const t = new Transcript();
  const lane = scriptedLane([{ text: "", error: "agent error" }]);
  let texts = 0;
  await runCard(lane, "answer", "Cedar", "Answer: what is Cedar?", "u1", deps(t), () => { texts += 1; });
  assert.equal(texts, 0);
});

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

test("#session-prompt-end a question after the session ends carries neither its prompt nor its conversation", async () => {
  const live = new LiveSession();
  const lane = scriptedLane([{ text: "a migration" }, { text: "no idea" }]);
  const d = { ...deps(live.transcript), sessionContext: () => live.context };

  live.start("Board meeting about the Cedar migration");
  say(live.transcript, "u1", "Cedar ships in March");
  await runCard(lane, "query", "Cedar", "Question: what is Cedar?", undefined, d);
  assert.match(lane.prompts[0], /Board meeting/, "a question in the session carries its prompt");
  assert.match(lane.prompts[0], /March/, "a question in the session carries its conversation");

  live.end();
  await runCard(lane, "query", "Cedar", "Question: what is Cedar?", undefined, d);
  assert.doesNotMatch(lane.prompts[1], /Board meeting/);
  assert.doesNotMatch(lane.prompts[1], /March/);
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

test("#lane-pool a session start mid-card aborts the busy lane but keeps it listed, under its name, until it releases", () => {
  const { pool: p, lanes, made, shed } = pool(1);
  p.free();
  const old = lanes.get("research0")!;
  old.busy = true;
  p.reset(); // a session start mid-card
  assert.equal(old.resets, 1, "its turn is aborted at once");
  assert.deepEqual(shed, ["research0"]);
  const fresh = p.all[0];
  assert.notEqual(fresh, old, "the rebuilt pool leads `all`: it is the warm-up target");
  assert.deepEqual(p.all, [fresh, old], "the old lane stays where cancel and the exit path look (#86)");
  assert.notEqual(fresh.name, old.name, "its name keys a cursor its card's failure path will still forget");
  p.release(old);
  assert.equal(old.busy, false);
  assert.deepEqual(p.all, [fresh], "the retired lane's release leaves the pool alone");
  // The name is reserved only while the lane is retired.
  p.resize(2);
  fresh.busy = true;
  assert.equal(p.free()?.name, "research0");
  assert.deepEqual(made, ["research0", "research1", "research0"]);
});

// An invariant test, not a reproduction: both backends settle an aborted turn
// synchronously inside reset(), so today runCard's forget lands before the new
// lane can be sent anything. The pool must not depend on that timing (#86).
test("#lane-pool the card a session start aborted cannot wipe the new lane's transcript cursor", async () => {
  const transcript = new Transcript();
  const { pool: p, lanes } = pool(1);
  const d = deps(transcript);
  const old = p.free()!;
  let settle!: (r: TaskResult) => void;
  old.session.run = () => new Promise<TaskResult>((resolve) => { settle = resolve; });
  old.busy = true;
  say(transcript, "u1", "Before the restart");
  const aborted = runCard(old, "answer", "old", "Answer: old?", "u1", d);
  // session_start: the conversation is cleared, the pool rebuilt, and the new
  // lane answers a card before the aborted turn has settled.
  transcript.clear();
  p.reset();
  const fresh = p.free()!;
  say(transcript, "u2", "After the restart");
  await runCard(fresh, "answer", "new", "Answer: new?", "u2", d);
  assert.equal(transcript.cursor(fresh.name), 1);
  // The aborted turn settles after that; runCard recycles its lane and
  // forgets that lane's cursor.
  settle({ text: "", error: "agent session reset" });
  await aborted;
  assert.equal(transcript.cursor(fresh.name), 1, "the new lane's cursor survives the old card's forget (#86)");
  say(transcript, "u3", "Next");
  await runCard(fresh, "answer", "next", "Answer: next?", "u3", d);
  const last = lanes.get(fresh.name)!.prompts.at(-1)!;
  assert.doesNotMatch(last, /After the restart/, "no replay of what the lane was already sent");
  assert.match(last, /Next/);
  // The pipeline releases the lane after runCard's own finally: only now is
  // the name free to mint again.
  p.release(old);
  assert.deepEqual(p.all, [fresh]);
  p.resize(2);
  fresh.busy = true;
  assert.equal(p.free()?.name, old.name);
});

test("#lane-pool a drop that throws at reset still retires that lane once and rebuilds the pool", () => {
  const { pool: p, lanes, shed } = pool(2);
  p.free();
  const [r0, r1] = [lanes.get("research0")!, lanes.get("research1")!]; // the rebuilt pool re-mints research1
  r0.busy = true;
  r0.session.reset = () => { throw new Error("stream torn down"); };
  p.reset();
  assert.equal(r1.resets, 1, "the lanes after the thrower are still dropped");
  assert.deepEqual(shed, ["research1"]);
  assert.deepEqual(p.all.map((l) => l.name), ["research1", "research2", "research0"], "rebuilt to size; the thrower retired once");
  p.release(r0);
  assert.deepEqual(p.all.map((l) => l.name), ["research1", "research2"]);
  assert.equal(p.free()?.name, "research1");
});

test("#lane-pool a second session start while a lane is retired retires the next, and drops each once", () => {
  const { pool: p, lanes, shed } = pool(1);
  p.free();
  const r0 = lanes.get("research0")!;
  r0.busy = true;
  p.reset();
  const r1 = lanes.get("research1")!;
  r1.busy = true;
  p.reset();
  const r2 = p.all[0];
  assert.deepEqual(p.all, [r2, r0, r1]);
  assert.equal(new Set(p.all.map((l) => l.name)).size, 3, "three names");
  assert.deepEqual(shed, ["research0", "research1"], "each shed once");
  assert.equal(r0.resets, 1);
  p.release(r0);
  p.release(r1);
  assert.deepEqual(p.all, [r2]);
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

/// QueryLanes over scripted lanes, named as QueryLanes names them, recording
/// the lanes it sheds.
function queryLanes(): { queries: QueryLanes; made: ReturnType<typeof scriptedLane>[]; shed: string[] } {
  const made: ReturnType<typeof scriptedLane>[] = [];
  const shed: string[] = [];
  const queries = new QueryLanes((name) => {
    const lane = scriptedLane([]);
    lane.name = name;
    made.push(lane);
    return lane;
  }, (lane) => shed.push(lane.name));
  return { queries, made, shed };
}

test("#query-lane a session start retires a query lane mid-answer, which finishes and is dropped after", async () => {
  // An Ask typed before Listen is still being answered when the session starts
  // (issue #104): its answer must arrive, not be cut off by the reset.
  const transcript = new Transcript();
  const d = deps(transcript);
  const { queries, made } = queryLanes();
  const old = queries.lane;
  let settle!: (r: TaskResult) => void;
  old.session.run = () => new Promise<TaskResult>((resolve) => { settle = resolve; });
  old.busy = true;
  const asked = runCard(old, "query", "Q", "Question: Q", undefined, d);

  transcript.clear();
  queries.reset();

  assert.equal(made[0]!.resets, 0, "the answer in flight isn't aborted");
  assert.notEqual(queries.lane, old, "the session gets a fresh lane");
  assert.equal(queries.lane.busy, false, "free for the session's own questions at once");
  assert.notEqual(queries.lane.name, old.name, "its own transcript cursor, which the old card's failure path can't forget");
  assert.deepEqual(queries.all, [queries.lane, old], "the retired lane stays where cancel and exit look");
  settle({ text: "The answer." });
  await asked;
  assert.deepEqual(d.sent.at(-1), { type: "card_update", id: "c1", body: "The answer.", state: "done" });
  queries.release(old);
  assert.equal(made[0]!.resets, 1, "its session is dropped once the card is over");
  assert.deepEqual(queries.all, [queries.lane]);
});

test("#query-lane a session start drops an idle query lane at once", () => {
  const { queries, made } = queryLanes();
  queries.reset();
  assert.equal(made[0]!.resets, 1);
  assert.deepEqual(queries.all, [made[1]]);
  // Releasing the current lane after a card only frees it; its session stays warm.
  made[1]!.busy = true;
  queries.release(made[1]!);
  assert.equal(made[1]!.busy, false);
  assert.equal(made[1]!.resets, 0);
});

test("#query-lane a retired lane's name is free again once its card is over", () => {
  const { queries } = queryLanes();
  const first = queries.lane;
  first.busy = true;
  queries.reset();
  const second = queries.lane;
  assert.deepEqual([first.name, second.name], ["query0", "query1"]);
  queries.release(first);
  queries.reset();
  assert.equal(queries.lane.name, "query0", "the lowest name not in use");
});

test("#query-lane a reset that throws still gives the session a fresh lane", () => {
  const { queries, made } = queryLanes();
  made[0]!.session.reset = () => { throw new Error("stream torn down"); };
  queries.reset();
  assert.notEqual(queries.lane, made[0]);
  assert.deepEqual(queries.all, [made[1]]);
});

test("#query-lane a dropped lane is shed, so a lane minted under its name starts with no cursor", () => {
  const { queries, made, shed } = queryLanes();
  queries.reset();
  assert.deepEqual(shed, ["query0"], "an idle lane, at the reset");
  made[1]!.busy = true;
  queries.reset();
  assert.deepEqual(shed, ["query0"], "a retired lane isn't shed while its card runs");
  queries.release(made[1]!);
  assert.deepEqual(shed, ["query0", made[1]!.name], "but once its card is over");
});

test("#query-lane a retired lane whose reset throws is still released", () => {
  const { queries, made } = queryLanes();
  made[0]!.busy = true;
  queries.reset();
  made[0]!.session.reset = () => { throw new Error("stream torn down"); };
  assert.doesNotThrow(() => queries.release(made[0]!));
  assert.deepEqual(queries.all, [made[1]]);
});

test("#query-lane a fresh lane that can't be made leaves the lanes as they were", () => {
  const lane = scriptedLane([]);
  lane.name = "query0";
  const queries = new QueryLanes((name) => {
    if (name !== "query0") throw new Error("no agent");
    return lane;
  });
  lane.busy = true;
  assert.throws(() => queries.reset());
  assert.deepEqual(queries.all, [lane], "not retired as well as current");
  assert.equal(lane.resets, 0);
});
