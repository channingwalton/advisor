// NDJSON protocol between the Swift app and this sidecar (see DESIGN.md).

export type Source = "me" | "them";

export type Inbound =
  // context: optional free-text the user enters before Listen (e.g. who's in
  // the meeting, what it's about) — injected into the research/query prompts.
  | { type: "session_start"; sessionId: string; ts: number; context?: string }
  // Live edit of the session prompt mid-session — replaces the current context,
  // applied to the next dispatched research/query/reply task.
  | { type: "session_context"; text: string }
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
  // Question asked about a saved past transcript, from the history browser. The
  // document (the whole transcript note) and the question are self-contained, so
  // it runs on a transient one-shot session with no live-session state (no
  // session context, no transcript delta), streamed back as document_answer on
  // the same id.
  | { type: "ask_document"; id: string; question: string; document: string }
  // Summarise the live session (issue #30). Carries the full transcript (not a
  // delta) and produces a single "summary" card. `cardId` is set on re-summarise
  // to the existing summary card, so the sidecar updates it in place rather than
  // emitting a second card; absent the first time. Streamed back as card/card_update.
  | { type: "summarise_live"; cardId?: string; transcript: string }
  // Summarise a saved past transcript (the history browser). Self-contained like
  // ask_document; streamed back as document_answer on the request id.
  | { type: "summarise_document"; id: string; transcript: string }
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
      kind: "answer" | "context" | "factcheck" | "query" | "summary";
      title: string;
      body: string;
      state: CardState;
    }
  | { type: "card_update"; id: string; body: string; state: CardState }
  // Streamed answer to an ask_document question, keyed by the request id.
  | { type: "document_answer"; id: string; body: string; state: CardState }
  | { type: "error"; fatal: boolean; message: string };

export function send(msg: Outbound): void {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

export function log(message: string): void {
  // Elapsed-since-start prefix so all log lines sit on one timeline.
  process.stderr.write(`[sidecar +${process.uptime().toFixed(1)}s] ${message}\n`);
}
