import { test } from "node:test";
import assert from "node:assert/strict";
import { handleCancel, type CancelLane, type CancelDeps } from "./cancel.js";
import type { Outbound } from "./protocol.js";

// A lane whose interrupt() records that it was called — enough of the surface
// handleCancel touches, without a real Agent session.
function fakeLane(name: string, cardId: string): CancelLane & { interrupted: boolean } {
  const lane = {
    name,
    currentCardId: cardId,
    interrupted: false,
    session: { interrupt: async () => { lane.interrupted = true; } },
  };
  return lane;
}

function makeDeps(
  cardLanes: CancelLane[] = [], documentLanes: CancelLane[] = []
): CancelDeps & { sent: Outbound[]; cancelledCards: Set<string> } {
  const sent: Outbound[] = [];
  return {
    cancelledCards: new Set<string>(),
    cardLanes,
    documentLanes,
    send: (m) => sent.push(m),
    sent,
  };
}

// The leak (issue #55): a cancel for an id no lane is running must NOT be added
// to cancelledCards — with no in-flight sender to suppress, the id would linger
// for the process lifetime. The app is still told it's cancelled.
test("cancel of an id with no running lane does not grow cancelledCards (issue #55)", () => {
  const deps = makeDeps();
  handleCancel("gone", deps);
  assert.equal(deps.cancelledCards.size, 0);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "gone", body: "cancelled", state: "cancelled" },
  ]);
});

// An in-flight card is marked cancelled (so its run's remaining sends are
// suppressed) and interrupted; the finally in its runner later clears the id.
test("cancel of a running card marks and interrupts it (issue #55)", () => {
  const lane = fakeLane("research0", "c1");
  const deps = makeDeps([lane]);
  handleCancel("c1", deps);
  assert.ok(deps.cancelledCards.has("c1"));
  assert.equal(lane.interrupted, true);
  assert.deepEqual(deps.sent, [
    { type: "card_update", id: "c1", body: "cancelled", state: "cancelled" },
  ]);
});

// A document task streams back as document_answer (keyed by request id on the
// app side); the cancel reply must use that frame, not card_update, or it is a
// silent no-op on the app (issue #55).
test("cancel of a running document task replies as document_answer (issue #55)", () => {
  const lane = fakeLane("document", "d1");
  const deps = makeDeps([], [lane]);
  handleCancel("d1", deps);
  assert.ok(deps.cancelledCards.has("d1"));
  assert.equal(lane.interrupted, true);
  assert.deepEqual(deps.sent, [
    { type: "document_answer", id: "d1", body: "cancelled", state: "cancelled" },
  ]);
});
