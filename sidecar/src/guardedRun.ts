import { Agent } from "./agent.js";
import { cardOutcome } from "./cards.js";
import { CardState, Outbound, log } from "./protocol.js";
import { throttle } from "./throttle.js";

/// Injected so guardedRun is testable without the module-global stdout `send`
/// and cancelledCards set.
export interface GuardedRunDeps {
  cancelledCards: Set<string>;
  send: (msg: Outbound) => void;
}

/// Builds the frame for one update. `activity` is set only while the agent is
/// doing something other than writing; a frame without it clears the line.
export type Frame = (body: string, state: CardState, activity?: string) => Outbound;

/// The longest a streaming card waits for its next frame. Text arrives every few
/// words and each frame resends the whole body, which the app re-renders.
const STREAM_INTERVAL_MS = 150;

/// The frame for a card: its body after `prefix` (a follow-up's thread so far),
/// and the activity line while there is one.
export function cardUpdateFrame(id: string, prefix = ""): Frame {
  return (body, state, activity) => ({
    type: "card_update", id, body: prefix + body, state, ...(activity ? { activity } : {}),
  });
}

/// Run `task` on `session`, streaming its output back through `frame` and
/// honouring a mid-flight cancel: while `cardId` sits in cancelledCards no
/// further frame is sent, so the app's "cancelled" state stands. Until text
/// arrives the card stays pending, showing what the agent is doing. Streaming
/// frames are rate-limited; the terminal frame always carries the whole answer.
/// Returns whether the turn failed (so a pooled lane can decide to recycle).
/// This is the shared skeleton behind every card / reply / summary / document
/// runner — they differ only in the `frame` they build (issue #66).
export async function guardedRun(
  session: Pick<Agent, "run">,
  cardId: string,
  task: string,
  frame: Frame,
  errorLabel: string,
  deps: GuardedRunDeps
): Promise<boolean> {
  let text = "";
  let activity: string | undefined;
  const live = throttle(() => {
    if (deps.cancelledCards.has(cardId)) return;
    deps.send(text ? frame(text, "streaming", activity) : frame("…", "pending", activity));
  }, STREAM_INTERVAL_MS);
  try {
    const result = await session.run(task, {
      onText: (body) => {
        text = body;
        activity = undefined; // writing again
        live.request();
      },
      onActivity: (line) => {
        activity = line;
        live.request();
      },
    });
    if (!deps.cancelledCards.has(cardId)) {
      const outcome = cardOutcome(result.text, result.error);
      deps.send(frame(outcome.body, outcome.state));
    }
    return Boolean(result.error);
  } catch (err) {
    log(`${errorLabel}: ${err}`);
    if (!deps.cancelledCards.has(cardId)) {
      deps.send(frame(`error: ${err instanceof Error ? err.message : String(err)}`, "failed"));
    }
    return true;
  } finally {
    // The terminal frame went out synchronously above; nothing may follow it.
    live.cancel();
  }
}
