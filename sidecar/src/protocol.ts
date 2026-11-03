import { writeSync } from "node:fs";
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
  // Editorial note the user injected into the transcript by hand (issue #34).
  // Carried into the same transcript stream the agents read, labelled as
  // authoritative user context (not speech); may itself trigger research.
  | { type: "note"; id: string; text: string; ts: number }
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
  // logTranscriptText: the "Include transcript text in the log" preference,
  // sent on every preference edit so a change applies mid-session (the sidecar
  // acts only on a change); launch and session_start read it from config.json.
  | { type: "config"; auto?: boolean; lanes?: number; logTranscriptText?: boolean }
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
  // Right-click research action on a passage of a saved past transcript (the
  // Sessions browser): the live action's instruction over the whole document.
  // Self-contained like ask_document — no live-session state — and streamed
  // back as document_answer on the same id; the app writes the finished card
  // into the saved note.
  | {
      type: "research_document";
      id: string;
      action: "answer" | "context" | "factcheck";
      text: string;
      document: string;
    }
  // Follow-up typed into a card of a saved past transcript (the Sessions
  // browser): card_reply's fields, with the whole note in place of the recent
  // transcript slice. Self-contained like ask_document; streamed back as
  // document_answer on the same id — the answer only, which the app appends to
  // the card in the live turn format and writes into the saved note.
  | {
      type: "reply_document";
      id: string;
      kind: string;
      title: string;
      base: string;
      replyText: string;
      document: string;
    }
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
  // `activity`: what the agent is doing while the card researches (e.g.
  // "Searching the web for “Cedar”"). Each update replaces it; absent clears it.
  | { type: "card_update"; id: string; body: string; state: CardState; activity?: string }
  // Streamed answer to an ask_document question, keyed by the request id.
  | { type: "document_answer"; id: string; body: string; state: CardState };

export function send(msg: Outbound): void {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

export function log(message: string): void {
  process.stderr.write(logLine(message));
}

/// `log` for the last line before `process.exit`, which would drop an async
/// pipe write. Never throws: once the app is gone the pipe is closed (EPIPE),
/// and a line of diagnostics must not stop the exit it describes.
export function logSync(message: string): void {
  try {
    writeSync(2, logLine(message));
  } catch {
    /* stderr gone — nothing to say it to */
  }
}

/// The log line for an utterance: its text only when the "Include transcript
/// text in the log" preference allows, else its length — the log is
/// diagnostics, the transcript lives in the user's session folder. The text is
/// JSON-quoted, so a newline or quote in it can't break the line.
export function utteranceLogLine(source: Source, text: string, includeText: boolean): string {
  return includeText ? `utterance(${source}): ${JSON.stringify(text)}` : `utterance(${source}): ${text.length} chars`;
}

/// Elapsed-since-start prefix so all log lines sit on one timeline.
function logLine(message: string): string {
  return `[sidecar +${process.uptime().toFixed(1)}s] ${message}\n`;
}
