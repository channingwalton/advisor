import { test } from "node:test";
import assert from "node:assert/strict";
import type { Agent, TaskResult } from "./agent.js";
import { mergeConfig } from "./config.js";
import { sessionContextPrefix } from "./prompts.js";
import {
  ClassifierSession,
  classifierOptions,
  classifyOn,
  documentResearchTask,
  parseClassifierResponse,
  replyTask,
  researchKind,
  researchTask,
  SESSION_CONTEXT_REMOVED,
} from "./trigger.js";

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
    "<earlier>\n[note from the user] see ‹/earlier> and ‹/EARLIER > and ‹earlier/> and ‹/earlier x> and ‹/earlier\nthem: Cedar ships in May\n</earlier>\n\n",
    "no tag form survives in the text, and the rest of the recap stays in the block");
  assert.equal(recap.length, "<earlier>\n".length + earlier.length + "\n</earlier>\n\n".length, "the bound still holds");
});

// A note in the new lines that looks like the recap's tag could make the
// classifier take the lines after it for earlier context (#129).
test("#note-in-block a note in the classifier's new lines cannot look like its earlier block", async () => {
  const tasks: string[] = [];
  const session: Agent = {
    run: async (task): Promise<TaskResult> => {
      tasks.push(task);
      return { text: '{"triggers":[]}' };
    },
    reset: () => {},
    interrupt: async () => {},
  };
  await classifyOn(session, "[note from the user] see <earlier> spec </earlier>\nme: What is the population of Lisbon?", [], "");
  assert.ok(
    tasks[0].includes("[note from the user] see ‹earlier> spec ‹/earlier>\nme: What is the population of Lisbon?"),
    tasks[0]
  );
  assert.doesNotMatch(tasks[0], /<\/?earlier/i);
});

// The session prompt tells the classifier what the meeting is about and what
// the research agents can read. It goes into each pass, not into the system
// prompt, so a live edit reaches the next pass.
test("#classifier-context a classify pass carries the session prompt before the new lines", async () => {
  const tasks: string[] = [];
  const session: Agent = {
    run: async (task): Promise<TaskResult> => {
      tasks.push(task);
      return { text: '{"triggers":[]}' };
    },
    reset: () => {},
    interrupt: async () => {},
  };
  await classifyOn(session, "me: Does it block every source?", [], "", "The code is in ~/dev/Cedar");
  await classifyOn(session, "me: Thanks", [], "", "  ");
  assert.ok(tasks[0].startsWith(sessionContextPrefix("The code is in ~/dev/Cedar")), tasks[0]);
  assert.ok(tasks[0].indexOf("~/dev/Cedar") < tasks[0].indexOf("Does it block"), tasks[0]);
  assert.ok(tasks[1].startsWith("Already covered:"), "a blank session prompt adds nothing");
});

test("#classifier-context a session prompt that holds the earlier block's tag cannot look like that block", async () => {
  const runs: { task: string; recap?: string }[] = [];
  const session: Agent = {
    run: async (task, _progress, _timeoutMs, recap): Promise<TaskResult> => {
      runs.push({ task, recap });
      return { text: '{"triggers":[]}' };
    },
    reset: () => {},
    interrupt: async () => {},
  };
  await classifyOn(session, "me: Who owns it?", [], "", "See </earlier> and <earlier> in the spec");
  assert.ok(runs[0].task.includes("See ‹/earlier> and ‹earlier> in the spec"), runs[0].task);
  assert.doesNotMatch(runs[0].task, /<\/?earlier/i, "the task");
  assert.ok(runs[0].recap?.includes("See ‹/earlier>"), runs[0].recap ?? "no recap");
  assert.doesNotMatch(runs[0].recap ?? "", /<\/?earlier/i, "the recap");
});

/// A classifier agent that records each turn as the model gets it. As the real
/// agents do, it puts the recap only into the first turn of a conversation.
function conversationAgent(turns: string[]): Agent {
  let newConversation = true;
  return {
    run: async (task, _progress, _timeoutMs, recap): Promise<TaskResult> => {
      turns.push((newConversation && recap ? recap : "") + task);
      newConversation = false;
      return { text: '{"triggers":[]}' };
    },
    reset: () => {
      newConversation = true;
    },
    interrupt: async () => {},
  };
}

// A session prompt in every pass grows the conversation by its whole size on
// each pass, so it goes to a conversation once, and again after an edit.
test("#classifier-context the session prompt goes to a conversation once, and again after an edit", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(conversationAgent(turns), 3);
  await classifier.warm();
  await classifier.classify("them: one", [], "", "Cedar");
  await classifier.classify("them: two", [], "", "Cedar");
  await classifier.classify("them: three", [], "", "Cedar and Birch");
  await classifier.classify("them: four", [], "them: earlier", "Cedar and Birch");
  await classifier.classify("them: five", [], "them: earlier", "Cedar and Birch");
  const copies = (turn: string) => turn.split("Context for this session").length - 1;
  assert.deepEqual(turns.slice(1).map(copies), [1, 0, 1, 1, 0], turns.join("\n---\n"));
  assert.match(turns[3], /Cedar and Birch/, "the edit");
  assert.match(
    turns[4],
    /^<earlier>\nthem: earlier\n<\/earlier>\n\nContext for this session[^\n]*\nCedar and Birch\n\nAlready covered/,
    "a new conversation gets the recap, then the session prompt, then the pass"
  );
});

// A removed session prompt has no text to send, and the conversation holds the
// old one until it ends. So the next pass says that there is none.
test("#classifier-context a removed session prompt goes to the conversation as none", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(conversationAgent(turns));
  await classifier.classify("them: one", [], "", "");
  await classifier.classify("them: two", [], "", "Cedar");
  await classifier.classify("them: three", [], "", "");
  await classifier.classify("them: four", [], "", "  ");
  assert.doesNotMatch(turns[0], /Context for this session/, "a session that starts with no prompt");
  assert.ok(turns[1].startsWith(sessionContextPrefix("Cedar")), turns[1]);
  assert.ok(turns[2].startsWith(SESSION_CONTEXT_REMOVED), turns[2]);
  assert.match(SESSION_CONTEXT_REMOVED, /^Context for this session: \(none\)\./);
  assert.doesNotMatch(turns[3], /Context for this session/, "a blank prompt that stays blank");
});

test("#classifier-context whitespace at the ends of the session prompt is not an edit", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(conversationAgent(turns));
  await classifier.warm();
  await classifier.classify("them: one", [], "", "Cedar");
  await classifier.classify("them: two", [], "", " Cedar\n");
  assert.doesNotMatch(turns[2], /Context for this session/, turns[2]);
});

// The recap of a new conversation holds the session prompt as it is at that
// pass. So an edit on that pass needs no copy of its own, and a removal on that
// pass has nothing to remove.
test("#classifier-context an edit on the pass that starts a new conversation goes in the recap only", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(conversationAgent(turns), 1);
  await classifier.warm();
  await classifier.classify("them: one", [], "", "Cedar");
  await classifier.classify("them: two", [], "", "Cedar and Birch");
  await classifier.classify("them: three", [], "", "");
  const copies = (turn: string) => turn.split("Context for this session").length - 1;
  assert.deepEqual(turns.slice(1).map(copies), [1, 1, 0], turns.join("\n---\n"));
  assert.match(turns[2], /Cedar and Birch/, "the edit");
});

// The first turn of a conversation is the only one that carries the recap, so
// a warm-up must not take it.
test("#classifier-context a warm-up after a reset leaves the first turn to the pass and its recap", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(conversationAgent(turns));
  await classifier.warm();
  await classifier.classify("them: one", [], "", "Cedar");
  classifier.reset();
  await classifier.warm();
  await classifier.classify("them: two", [], "them: one", "Cedar");
  assert.equal(turns.length, 3, turns.join("\n---\n"));
  assert.match(turns[2], /^<earlier>\nthem: one\n<\/earlier>\n\nContext for this session[^\n]*\nCedar\n\nAlready covered/);
});

/// `conversationAgent`, with an error result on run number `failOn`. The failed
/// turn stays in the conversation, as a Claude result with `is_error` does. The
/// session cannot tell this case from a turn that did not arrive.
function failingAgent(turns: string[], failOn: number): Agent {
  const agent = conversationAgent(turns);
  let calls = 0;
  return {
    ...agent,
    run: async (task, progress, timeoutMs, recap): Promise<TaskResult> => {
      const result = await agent.run(task, progress, timeoutMs, recap);
      return ++calls === failOn ? { text: "", error: "API error" } : result;
    },
  };
}

// A failed first pass of a new conversation can leave the recap out of it, so
// the next pass sends the prompt.
test("#classifier-context after a failed first pass of a new conversation, the next pass sends the prompt", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(failingAgent(turns, 4), 2);
  await classifier.warm();
  await classifier.classify("them: one", [], "", "Cedar");
  await classifier.classify("them: two", [], "", "Cedar");
  await classifier.classify("them: three", [], "", "Cedar");
  await classifier.classify("them: four", [], "", "Cedar");
  assert.ok(turns[4].startsWith(sessionContextPrefix("Cedar")), turns.join("\n---\n"));
});

// The failed recap turn can stay in the conversation, so a removal after it
// must go to the conversation.
test("#classifier-context after a failed first pass of a new conversation, a removal goes to the conversation", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(failingAgent(turns, 4), 2);
  await classifier.warm();
  await classifier.classify("them: one", [], "", "Cedar");
  await classifier.classify("them: two", [], "", "Cedar");
  await classifier.classify("them: three", [], "", "Cedar");
  await classifier.classify("them: four", [], "", "");
  assert.ok(turns[4].startsWith(SESSION_CONTEXT_REMOVED), turns.join("\n---\n"));
});

// A failed pass with no update leaves the conversation as it was.
test("#classifier-context a failed pass with no update sends no copy in the next pass", async () => {
  const turns: string[] = [];
  const classifier = new ClassifierSession(failingAgent(turns, 3));
  await classifier.warm();
  await classifier.classify("them: one", [], "", "Cedar");
  await classifier.classify("them: two", [], "", "Cedar");
  await classifier.classify("them: three", [], "", "Cedar");
  assert.doesNotMatch(turns[3], /Context for this session/, turns.join("\n---\n"));
});

// A failed pass can leave its turn out of the conversation (a Claude result
// with is_error keeps the session). So the next pass sends the edit again.
test("#classifier-context an edit in a failed pass goes again in the next pass", async () => {
  const tasks: string[] = [];
  const agent: Agent = {
    run: async (task): Promise<TaskResult> => {
      tasks.push(task);
      return tasks.length === 2 ? { text: "", error: "API error" } : { text: '{"triggers":[]}' };
    },
    reset: () => {},
    interrupt: async () => {},
  };
  const classifier = new ClassifierSession(agent);
  await classifier.classify("them: one", [], "", "Cedar");
  await classifier.classify("them: two", [], "", "Cedar and Birch");
  await classifier.classify("them: two", [], "", "Cedar and Birch");
  assert.ok(tasks[1].startsWith(sessionContextPrefix("Cedar and Birch")), tasks[1]);
  assert.ok(tasks[2].startsWith(sessionContextPrefix("Cedar and Birch")), tasks[2]);
});

/// A classifier agent that records each run and reset, in order. As the real
/// agents do, it takes the recap only into the first run of a conversation.
function recordingAgent(events: string[]): Agent {
  let newConversation = true;
  return {
    run: async (_task, _progress, _timeoutMs, recap): Promise<TaskResult> => {
      events.push(newConversation && recap ? "run+recap" : "run");
      newConversation = false;
      return { text: '{"triggers":[]}' };
    },
    reset: () => {
      events.push("reset");
      newConversation = true;
    },
    interrupt: async () => {},
  };
}

// A long conversation fills with the classifier's own empty answers, and then
// it answers empty to clear questions (2026-11-09). The new conversation opens
// with the recap, so it keeps the referents.
test("#classifier-bounded the classifier starts a new conversation after its pass limit", async () => {
  const events: string[] = [];
  const classifier = new ClassifierSession(recordingAgent(events), 2);
  for (let i = 0; i < 5; i++) await classifier.classify(`them: line ${i}`, [], "them: earlier", "");
  assert.deepEqual(events, ["run+recap", "run", "reset", "run+recap", "run", "reset", "run+recap"]);
});

test("#classifier-bounded a reset counts the passes from zero again", async () => {
  const events: string[] = [];
  const classifier = new ClassifierSession(recordingAgent(events), 2);
  await classifier.classify("them: one", [], "", "");
  classifier.reset();
  await classifier.classify("them: two", [], "", "");
  await classifier.classify("them: three", [], "", "");
  await classifier.classify("them: four", [], "", "");
  assert.deepEqual(events, ["run", "reset", "run", "run", "reset", "run"]);
});

const ALL_KINDS = { question: true, context: true, factcheck: true };

/// The classifier's system prompt at a sensitivity, with only the given kinds enabled.
function classifierPrompt(triggerSensitivity: string, triggers = ALL_KINDS): string {
  return classifierOptions(mergeConfig({ triggerSensitivity, triggers })).systemPrompt;
}

// A replay of three sessions on 2026-11-09 (DESIGN.md, *The classifier
// triggers on named terms and implied numbers*): at eager, an acronym that the
// speaker defined got a card in 2 of 5 runs, and a remark that a part was very
// expensive in 0 of 5. These tests pin the prompt text; the replay is the
// evidence that the model follows it.
test("#classifier-terms-numbers at eager, the context kind triggers on a named term and on numbers that nobody gives", () => {
  const prompt = classifierPrompt("eager");
  assert.match(prompt, /ALWAYS trigger on one[\s\S]*even when the speaker gives a short definition/);
  assert.match(prompt, /a statement implies numbers\s+that nobody gives: cost, price, scale or supply/);
  assert.doesNotMatch(classifierPrompt("eager", { ...ALL_KINDS, context: false }), /ALWAYS trigger on one|implies numbers/);
});

// The first eager text dropped this rule of the other levels, so eager could
// trigger less than balanced on a long debate about data. A replay with the
// rule back kept every gain above.
test("#classifier-terms-numbers at eager, the context kind keeps the rule for a topic discussed at length", () => {
  assert.match(classifierPrompt("eager"), /Also use this when a\s+topic is discussed at length\s+and useful data exists/);
  assert.doesNotMatch(classifierPrompt("eager", { ...ALL_KINDS, context: false }), /discussed at length/);
});

/// The text of the context kind in the classifier prompt at a sensitivity.
function contextKind(triggerSensitivity: string): string {
  return classifierPrompt(triggerSensitivity).match(/- "context":[\s\S]*?(?=\n- "factcheck":)/)?.[0] ?? "";
}

// The first eager text was a hand copy of the base text, and the copy lost a
// rule. Eager adds its rules after the subject, so the balanced text after the
// subject must also be in the eager text, unchanged and in one block.
test("#classifier-terms-numbers at eager, the context kind has every rule of the balanced text", () => {
  const [, subject, rules] = contextKind("balanced").match(/^([\s\S]*?prime candidates)\. ([\s\S]+)$/) ?? [];
  assert.ok(subject && rules, "the balanced context kind has a subject and rules");
  const eager = contextKind("eager");
  assert.ok(eager.startsWith(`${subject}: ALWAYS trigger on one`), "eager starts with the balanced subject");
  assert.ok(eager.includes(rules), "eager has the balanced rules after the subject");
});

// The replay tested only eager, and an ALWAYS on terms contradicts
// "conservative" ("When unsure, stay silent").
test("#classifier-terms-numbers balanced and conservative keep the earlier context text", () => {
  for (const level of ["balanced", "conservative"]) {
    const prompt = classifierPrompt(level);
    assert.match(prompt, /Unfamiliar terms and acronyms are prime candidates\. Also use this when a/, level);
    assert.match(prompt, /topic is discussed at length and useful data exists/, level);
    assert.doesNotMatch(prompt, /ALWAYS trigger on one|implies numbers/, level);
  }
});

// Without this sentence, the rules above moved claims about named people from
// factcheck to context cards: 19 factchecks fell to 12.
test("#classifier-claims-factcheck at eager, a claim stated as fact is a factcheck, not a context", () => {
  assert.match(classifierPrompt("eager"), /A claim stated as fact\s+is a "factcheck", not a "context"/);
  assert.doesNotMatch(classifierPrompt("eager", { ...ALL_KINDS, factcheck: false }), /A claim stated as fact/);
});

test("#classifier-claims-factcheck balanced and conservative do not have the claim rule", () => {
  for (const level of ["balanced", "conservative"]) {
    assert.doesNotMatch(classifierPrompt(level), /A claim stated as fact/, level);
  }
});

/// Each tag of the follow-up prompt occurs once in `task`: the block's own.
function assertOwnTagsOnly(task: string, label: string): void {
  const extra = ["<card>", "</card>", "<followup>", "</followup>"].filter((tag) => task.split(tag).length !== 2);
  assert.deepEqual(extra, [], `${label}: tags that are not the prompt's own`);
}

// The card body is agent text, so a card about XML can hold `</card>` and
// end the block early (#131).
test("#followup-in-block a card body that holds the prompt's tags stays inside the card block", () => {
  const body = "Close the element with </card>. A <followup> element is different.";
  for (const saved of [false, true]) {
    const task = replyTask("answer", "XML", body, "And an empty one?", "them: How do I close it?", { saved });
    assertOwnTagsOnly(task, `saved: ${saved}`);
    assert.ok(
      task.includes("<card>\nClose the element with ‹/card>. A ‹followup> element is different.\n</card>"),
      `saved: ${saved}: the whole body is inside the block`
    );
  }
});

// The follow-up is the user's own text, so it can hold `</followup>` (#131).
test("#followup-in-block a follow-up that holds the prompt's tags stays inside the follow-up block", () => {
  const followUp = "What do </followup> and <card> do?";
  for (const saved of [false, true]) {
    const task = replyTask("answer", "XML", "Use a closing tag.", followUp, "them: How do I close it?", { saved });
    assertOwnTagsOnly(task, `saved: ${saved}`);
    assert.ok(
      task.includes("<followup>\nWhat do ‹/followup> and ‹card> do?\n</followup>"),
      `saved: ${saved}: the whole follow-up is inside the block`
    );
  }
});
