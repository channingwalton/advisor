import { Agent } from "./agent.js";
import { cardOutcome } from "./cards.js";
import { CardState, Outbound, log } from "./protocol.js";

/// Injected so guardedRun is testable without the module-global stdout `send`
/// and cancelledCards set.
export interface GuardedRunDeps {
  cancelledCards: Set<string>;
  send: (msg: Outbound) => void;
}

/// Run `task` on `session`, streaming its output back through `frame(body,
/// state)` and honouring a mid-flight cancel: while `cardId` sits in
/// cancelledCards no further frame is sent, so the app's "cancelled" state
/// stands. Returns whether the turn failed (so a pooled lane can decide to
/// recycle). This is the shared skeleton behind every card / reply / summary /
/// document runner — they differ only in the `frame` they build (issue #66).
export async function guardedRun(
  session: Pick<Agent, "run">,
  cardId: string,
  task: string,
  frame: (body: string, state: CardState) => Outbound,
  errorLabel: string,
  deps: GuardedRunDeps
): Promise<boolean> {
  try {
    const { text, error } = await session.run(task, (body) => {
      if (!deps.cancelledCards.has(cardId)) deps.send(frame(body, "streaming"));
    });
    if (!deps.cancelledCards.has(cardId)) {
      const outcome = cardOutcome(text, error);
      deps.send(frame(outcome.body, outcome.state));
    }
    return Boolean(error);
  } catch (err) {
    log(`${errorLabel}: ${err}`);
    if (!deps.cancelledCards.has(cardId)) {
      deps.send(frame(`error: ${err instanceof Error ? err.message : String(err)}`, "failed"));
    }
    return true;
  }
}
