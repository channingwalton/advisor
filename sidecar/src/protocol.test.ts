import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { utteranceLogLine, type Inbound, type Outbound } from "./protocol.js";

// The protocol is written down twice — `Inbound`/`Outbound` in protocol.ts and
// string-keyed dictionaries in SidecarManager.swift — over a pipe neither side
// checks the shape of, so a field renamed on one side showed up as empty cards
// or ignored frames with both suites green. `protocol/examples.json` is the one
// set of frames both suites hold their side to (issue #97). Here each example
// is held to its type's field names and primitive kinds; the app's
// ProtocolContractTests feeds the same frames through SidecarManager.
//
// The descriptors below bridge the types to the test: the compiler holds each
// entry to its variant — a field renamed, added or dropped on the type, a
// variant added or removed, or an optional field made required, is an error on
// this file — and the test holds the examples to the entries.

type Variant<T, K> = Extract<T, { type: K }>;
type Kind<V> = [V] extends [string] ? "string"
  : [V] extends [number] ? "number"
  : [V] extends [boolean] ? "boolean"
  : never;
type Fields<T extends { type: string }> = {
  [K in T["type"]]: {
    [F in Exclude<keyof Variant<T, K>, "type">]-?: undefined extends Variant<T, K>[F]
      ? `${Kind<Exclude<Variant<T, K>[F], undefined>>}?`
      : Kind<Variant<T, K>[F]>;
  };
};

/// App → sidecar. A trailing `?` marks a field the app may leave out.
const inbound: Fields<Inbound> = {
  session_start: { sessionId: "string", ts: "number", context: "string?" },
  session_context: { text: "string" },
  utterance: { id: "string", source: "string", text: "string", ts: "number" },
  note: { id: "string", text: "string", ts: "number" },
  query: { id: "string", text: "string", action: "string?", triggerId: "string?" },
  config: { auto: "boolean?", lanes: "number?", logTranscriptText: "boolean?" },
  cancel: { cardId: "string" },
  card_reply: {
    cardId: "string", kind: "string", title: "string", base: "string", replyText: "string",
    transcript: "string?",
  },
  ask_document: { id: "string", question: "string", document: "string" },
  research_document: { id: "string", action: "string", text: "string", document: "string" },
  reply_document: {
    id: "string", kind: "string", title: "string", base: "string", replyText: "string",
    document: "string",
  },
  summarise_live: { cardId: "string?", transcript: "string" },
  summarise_document: { id: "string", transcript: "string" },
  session_end: {},
};

/// Sidecar → app.
const outbound: Fields<Outbound> = {
  hello: { version: "number" },
  card: { id: "string", trigger: "string?", kind: "string", title: "string", body: "string", state: "string" },
  card_update: { id: "string", body: "string", state: "string", activity: "string?" },
  document_answer: { id: "string", body: "string", state: "string" },
  error: { fatal: "boolean", message: "string" },
};

type Frame = { type: string } & Record<string, unknown>;
/// One direction of the examples: the frames, and per type the fields a frame
/// may leave out (the Swift test needs that; the types carry it as `?`).
type Direction = { frames: Frame[]; optional: Record<string, string[]> };
const examples = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../protocol/examples.json", import.meta.url)), "utf8"),
) as { appToSidecar: Direction; sidecarToApp: Direction };

/// Every frame type has exactly one example; each example carries exactly its
/// type's fields (optional ones included — the examples are the full form),
/// each of the type's primitive kind; and `optional` names exactly the type's
/// optional fields.
function holdExamplesToTypes(direction: string, { frames, optional }: Direction, fields: Record<string, Record<string, string>>) {
  assert.deepEqual(
    frames.map((f) => f.type).sort(),
    Object.keys(fields).sort(),
    `${direction}: one example per frame type`,
  );
  for (const [type, names] of Object.entries(optional)) {
    assert.ok(type in fields, `${direction} optional: no such type ${type}`);
    assert.ok(Array.isArray(names), `${direction} optional.${type}: must be an array of field names`);
  }
  for (const { type, ...rest } of frames) {
    const spec = fields[type];
    assert.deepEqual(Object.keys(rest).sort(), Object.keys(spec).sort(), `${direction} ${type}: field names`);
    for (const [name, kind] of Object.entries(spec)) {
      assert.equal(typeof rest[name], kind.replace(/\?$/, ""), `${direction} ${type}.${name}: kind`);
    }
    assert.deepEqual(
      [...(optional[type] ?? [])].sort(),
      Object.entries(spec).filter(([, kind]) => kind.endsWith("?")).map(([name]) => name).sort(),
      `${direction} ${type}: optional fields`,
    );
  }
}

test("#97 the app → sidecar examples are the Inbound frames, one per type", () => {
  holdExamplesToTypes("app → sidecar", examples.appToSidecar, inbound);
});

test("#97 the sidecar → app examples are the Outbound frames, one per type", () => {
  holdExamplesToTypes("sidecar → app", examples.sidecarToApp, outbound);
});

// The log is diagnostics; the transcript lives in the user's session folder
// (code review 2026-10-17). An utterance's text reaches the log only with the
// "Include transcript text in the log" preference on, as the app's own line.
test("an utterance's log line carries its length by default", () => {
  assert.equal(utteranceLogLine("them", "the quarterly numbers", false), "utterance(them): 21 chars");
});

test("an utterance's log line carries its text when the preference is on", () => {
  assert.equal(utteranceLogLine("them", "the quarterly numbers", true), 'utterance(them): "the quarterly numbers"');
});

test("an utterance's text stays on its log line, quotes and newlines escaped", () => {
  assert.equal(
    utteranceLogLine("them", 'it said "done"\n[sidecar +1.0s] classify', true),
    'utterance(them): "it said \\"done\\"\\n[sidecar +1.0s] classify"',
  );
});
