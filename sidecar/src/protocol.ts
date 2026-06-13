// NDJSON protocol between the Swift app and this sidecar (see DESIGN.md).

export type Source = "me" | "them";

export type Inbound =
  | { type: "session_start"; sessionId: string; ts: number }
  | { type: "utterance"; id: string; source: Source; text: string; ts: number }
  // Manual user action. action+triggerId are set by the right-click menu:
  // action picks the prompt/card kind, triggerId anchors the card under the
  // clicked utterance. Both absent for the free-text Ask box (legacy query).
  | {
      type: "query";
      id: string;
      text: string;
      action?: "answer" | "context" | "factcheck";
      triggerId?: string;
    }
  | { type: "config"; auto?: boolean; lanes?: number }
  | { type: "cancel"; cardId: string }
  // Follow-up typed into an existing card. The sidecar holds no card state, so
  // the app sends everything needed to answer in context: the card's current
  // body (original answer + any prior follow-up turns), the new question, and a
  // recent transcript slice for resolving referents. Answered by a transient
  // one-shot session (outside the research pool), streamed back as card_update
  // on the same cardId.
  | {
      type: "card_reply";
      cardId: string;
      kind: "answer" | "context" | "factcheck" | "query";
      title: string;
      base: string;
      replyText: string;
      transcript?: string;
    }
  | { type: "session_end" };

export type CardState = "pending" | "streaming" | "done" | "failed" | "cancelled";

export type Outbound =
  | { type: "hello"; version: number }
  | {
      type: "card";
      id: string;
      // Utterance id this card answers, so the app anchors it under that
      // sentence rather than at research-completion time. Absent for user queries.
      trigger?: string;
      kind: "answer" | "context" | "factcheck" | "query";
      title: string;
      body: string;
      state: CardState;
    }
  | { type: "card_update"; id: string; body: string; state: CardState }
  | { type: "usage"; sessionCostUsd: number }
  | { type: "error"; fatal: boolean; message: string };

export function send(msg: Outbound): void {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

export function log(message: string): void {
  // Elapsed-since-start prefix so all log lines sit on one timeline.
  process.stderr.write(`[sidecar +${process.uptime().toFixed(1)}s] ${message}\n`);
}
