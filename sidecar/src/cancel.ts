import { Agent } from "./agent.js";
import { Outbound, log } from "./protocol.js";

/// The lane fields `handleCancel` needs — a structural subset of main's `Lane`,
/// kept here so this module has no dependency on (or import cycle with) main.ts.
export interface CancelLane {
  name: string;
  currentCardId?: string;
  session: Pick<Agent, "interrupt">;
}

/// Dependencies for `handleCancel`, injected so it stays testable without the
/// module-global lane pools and stdout `send`.
export interface CancelDeps {
  cancelledCards: Set<string>;
  /// Card-bearing lanes (research + query + reply + summary), searched by
  /// `currentCardId`.
  cardLanes: CancelLane[];
  /// History-browser document lanes, searched the same way but replied to as
  /// document_answer rather than card_update.
  documentLanes: CancelLane[];
  send: (msg: Outbound) => void;
}

/// Cancel the run behind `cardId`. Mark it cancelled *only* while a lane is
/// actually running it — otherwise there is no in-flight sender to suppress and
/// the id would linger in `cancelledCards` for the process lifetime; an
/// in-flight run clears its own id in its finally, so the set stays bounded by
/// the number of running lanes (issue #55). Route the terminal frame by which
/// pool owns the id: a document task streams back as document_answer (keyed by
/// request id on the app side), a card as card_update — sending the wrong one is
/// a silent no-op on the app.
export function handleCancel(cardId: string, deps: CancelDeps): void {
  const docLane = deps.documentLanes.find((l) => l.currentCardId === cardId);
  const lane = docLane ?? deps.cardLanes.find((l) => l.currentCardId === cardId);
  if (lane) {
    deps.cancelledCards.add(cardId);
    log(`cancelling ${cardId} on ${lane.name}`);
    void lane.session.interrupt().catch((err) => log(`interrupt failed: ${err}`));
  }
  deps.send(
    docLane
      ? { type: "document_answer", id: cardId, body: "cancelled", state: "cancelled" }
      : { type: "card_update", id: cardId, body: "cancelled", state: "cancelled" }
  );
}
