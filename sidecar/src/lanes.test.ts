import { test } from "node:test";
import assert from "node:assert/strict";
import type { TaskResult } from "./agent.js";
import type { Outbound } from "./protocol.js";
import { cardLaneOptions, runCard, Transcript, type Lane, type RunCardDeps } from "./lanes.js";
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
