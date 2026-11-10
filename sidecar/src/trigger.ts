import { Agent, type AgentSessionOptions, type TaskResult } from "./agent.js";
import { createAgent } from "./providers.js";
import { AdvisorConfig, modelArg } from "./config.js";
import { log } from "./protocol.js";
import { escapeTags, sessionContextPrefix } from "./prompts.js";

/// Safety cap on triggers emitted per classification pass — bounds card spam
/// and concurrent research lanes from one noisy window. The user steers volume
/// via triggerSensitivity; this is just a backstop, not a preference.
const MAX_TRIGGERS_PER_PASS = 2;

/// Classify passes in one classifier conversation. A pass runs after each
/// pause in speech, about every 5 s, so 30 passes is about 2.5 minutes. A
/// longer conversation fills with the classifier's own empty answers, and then
/// it answers empty to clear questions (2026-11-09).
export const CLASSIFIER_PASSES_PER_CONVERSATION = 30;

export type ResearchKind = "question" | "context" | "factcheck";

export interface Trigger {
  kind: ResearchKind;
  subject: string;
  query: string;
  // Utterance id of the line that completed this trigger; set by the caller
  // (the classifier LLM never sees ids). Carried through to the card so the
  // app can anchor it under that sentence.
  anchorId?: string;
}

/// Card kind shown to the user for a research kind. "question" surfaces as
/// "answer"; the rest are unchanged.
export function cardKind(kind: ResearchKind): "answer" | "context" | "factcheck" {
  return kind === "question" ? "answer" : kind;
}

/// The research instruction sent to a lane. Single source of truth shared by
/// the auto-trigger pipeline and manual (right-click / Ask box) actions, so
/// both phrase each kind identically.
export function researchTask(kind: ResearchKind, subject: string, query: string): string {
  switch (kind) {
    case "question":
      return `Answer this question from the conversation: ${query}`;
    case "factcheck":
      return `Fact-check this claim from the conversation: "${query}". Give a verdict first (true / false / mixed / couldn't verify), then the evidence with sources.`;
    case "context":
      return `Give brief, useful background on "${subject}" as it relates to the conversation: ${query}`;
  }
}

/// The research kind for an app action name ("answer" | "context" |
/// "factcheck"), or undefined for anything else — so a bad action fails fast
/// rather than reaching an agent as a broken prompt.
export function researchKind(action: string): ResearchKind | undefined {
  switch (action) {
    case "answer":
      return "question";
    case "context":
    case "factcheck":
      return action;
    default:
      return undefined;
  }
}

/// A research action (right-click Answer / Context / Fact check) on a line of a
/// saved past transcript, from the Sessions browser. The same instruction as a
/// live action (`researchTask`), but with the whole saved transcript as context
/// in place of the live delta — there is no live session behind it.
export function documentResearchTask(kind: ResearchKind, query: string, document: string): string {
  return (
    `The user is reading a saved transcript of a past conversation and picked a passage from it.\n\n` +
    `<transcript>\n${escapeTags(document)}\n</transcript>\n\n` +
    researchTask(kind, query, query)
  );
}

/// The instruction for a follow-up on an existing card. The sidecar is stateless
/// about cards, so the app supplies the card's current body and a recent
/// transcript slice; this reconstructs the context for a transient one-shot
/// session. Mirrors researchTask: single source of truth for the reply prompt.
/// `saved` is a card on a saved session (the Sessions browser), where the
/// "transcript" is the whole saved note — cards included — not a live slice.
export function replyTask(
  kind: string,
  title: string,
  cardBody: string,
  followUp: string,
  transcript: string,
  options: { saved?: boolean } = {}
): string {
  const saved = options.saved ?? false;
  const ctx = !transcript.trim()
    ? ""
    : saved
      ? `\n\nThe saved session note it belongs to (transcript and other cards):\n<transcript>\n${escapeTags(transcript.trim())}\n</transcript>`
      : `\n\nRecent conversation transcript (resolve references like "she"/"that" against it):\n<transcript>\n${escapeTags(transcript.trim())}\n</transcript>`;
  const origin = saved
    ? `This ${kind} card titled "${title}" is from a saved session the user is reviewing:`
    : `You previously produced this ${kind} card titled "${title}" during a live conversation:`;
  return (
    `${origin}\n\n` +
    `<card>\n${escapeTags(cardBody)}\n</card>` +
    ctx +
    `\n\nThe user has a follow-up about that card:\n<followup>\n${escapeTags(followUp)}\n</followup>\n\n` +
    `Answer the follow-up concisely, leading with the answer. Use the card and transcript as context; don't repeat the card's content unless needed.`
  );
}

const SENSITIVITY: Record<string, string> = {
  conservative:
    "Be conservative: only trigger on clear, explicit questions or obviously important topics. When unsure, stay silent.",
  balanced:
    "In an active, substantive conversation expect a trigger every couple of minutes. Stay silent for pleasantries and chit-chat.",
  eager:
    "Be eager: in substantive conversation aim for a trigger every minute or two; returning empty triggers constantly means you are failing. When a topic could plausibly benefit from research, trigger.",
};

const KIND_DESCRIPTIONS: Record<keyof AdvisorConfig["triggers"], string> = {
  question: `- "question": a factual question asked or wondered aloud (incl. implicit/musing forms:
  "I wonder", "not sure what", "does anyone know", "how does X work") that the transcript
  doesn't answer. ALWAYS trigger on these. This INCLUDES personal questions about the
  user's own notes, projects, or work history ("what did I change in X", "when did
  I last...", "what's in my notes about...") — the research agent can search the user's
  notes, so these are among the MOST valuable triggers.`,
  context: `- "context": a named project, system, person, company, product, acronym, ticket, or topic
  is being discussed where background, definitions, or recent news would help a
  participant. Unfamiliar terms and acronyms are prime candidates. Also use this when a
  topic is discussed at length and useful data exists (e.g. they debate costs → fetch the
  actual numbers).`,
  factcheck: `- "factcheck": a specific checkable claim was stated as fact (numbers, dates,
  capabilities, "X said/does Y") and verifying it would add value.`,
};

/// The context and factcheck kinds at "eager" (DESIGN.md, *The classifier
/// triggers on named terms and implied numbers*). A replay tested this text
/// only at eager, and its ALWAYS on terms contradicts "conservative", so the
/// other sensitivities keep KIND_DESCRIPTIONS.
const EAGER_KIND_DESCRIPTIONS: Pick<typeof KIND_DESCRIPTIONS, "context" | "factcheck"> = {
  context: `- "context": a named project, system, person, company, product, acronym, ticket, or topic
  is being discussed where background, definitions, or recent news would help a
  participant. Unfamiliar terms and acronyms are prime candidates: ALWAYS trigger on one
  (e.g. "RAG", "TPU", "GDPR"), even when the speaker gives a short definition, because the
  card adds the depth that the speaker skips. Also use this when a statement implies numbers
  that nobody gives: cost, price, scale or supply (e.g. "these licences are very
  expensive") → fetch the actual numbers. Also use this when a topic is discussed at length
  and useful data exists (e.g. they debate costs → fetch the actual numbers).`,
  factcheck: `${KIND_DESCRIPTIONS.factcheck} A claim stated as fact
  is a "factcheck", not a "context", even when it names a person, role or topic.`,
};

function classifierSystem(cfg: AdvisorConfig): string {
  const descriptions =
    cfg.triggerSensitivity === "eager" ? { ...KIND_DESCRIPTIONS, ...EAGER_KIND_DESCRIPTIONS } : KIND_DESCRIPTIONS;
  const kinds = (Object.keys(descriptions) as (keyof AdvisorConfig["triggers"])[])
    .filter((k) => cfg.triggers[k])
    .map((k) => descriptions[k])
    .join("\n");
  return `You are the trigger detector for a proactive realtime meeting
assistant. Each user message contains the lines of a LIVE SPEECH-TO-TEXT transcript that
are NEW since your previous message. You have already seen everything before that, so
evaluate every new line exactly once — never let one pass unjudged, and join new
fragments with the tail of what you saw previously.

Important properties of the input:
- Sentences are often SPLIT ACROSS LINES mid-thought. Mentally reassemble adjacent lines
  from the same speaker into complete sentences before judging.
- Echo may cause NEAR-DUPLICATE lines from different speakers — treat them as one.
- Punctuation and capitalisation are unreliable. A question may have no question mark.
- A line beginning "[note from the user]" is an editorial note the user typed by hand, not
  speech. Trust it as authoritative context, use it to disambiguate the surrounding lines,
  and trigger research on it when it warrants looking something up.
- A message can start with an <earlier> block: the conversation before the new lines, which
  you did not see. Use it only to understand the new lines. Never trigger on it.
- After the <earlier> block, a message can carry the user's "Context for this session": who is
  present, the topic, and the projects, notes or code that the research agents can read. It
  comes early in the conversation and again after each edit, and it holds until a new one
  comes. "Context for this session: (none)" means that no context applies now. Use it to
  judge the new lines: a question about something it names is worth a trigger, because the
  research agents can look it up. Never trigger on the context itself.
- Then come the "Already covered" list and the new transcript lines.

Your mission: behave like a sharp assistant sitting in the meeting who looks things up
BEFORE being asked. ${SENSITIVITY[cfg.triggerSensitivity] ?? SENSITIVITY.balanced}
Never trigger on meta-talk about this app.

Reply to EVERY message with STRICT JSON only, no prose, no markdown:
{"triggers":[{"kind":"question","subject":"...","query":"..."}]}

kind is one of:
${kinds}

Rules:
- Reassembled-sentence questions count even if split across lines.
- Skip anything whose subject is in the "already covered" list of the message.
- Max ${MAX_TRIGGERS_PER_PASS} triggers per message. "subject" is a short dedup key; "query" is a
  self-contained research instruction (include enough context to be understood alone).`;
}

/// The line that a pass carries when the session prompt is blank and the
/// conversation can hold an old one, which a blank prompt has no text to
/// replace. Its words are also correct for a conversation that holds none.
export const SESSION_CONTEXT_REMOVED = "Context for this session: (none). Drop the previous session context.\n\n";

/// The classifier's agent, with a new conversation after each
/// `passLimit` passes. The agent opens a new conversation with the recap
/// (`earlier` and the session prompt), so the next pass keeps the referents of
/// what was said (#116).
export class ClassifierSession {
  private passes = 0;
  /// The session prompt that the conversation holds: blank at the start, and
  /// undefined when that is not known. A failed pass that carried an update
  /// can be in the conversation or not, so the next pass states the prompt.
  private lastContext?: string = "";
  /// True after `reset()`: the next turn starts a conversation with the recap.
  private recapPending = false;

  constructor(
    private readonly agent: Agent,
    private readonly passLimit = CLASSIFIER_PASSES_PER_CONVERSATION
  ) {}

  /// One classify pass (see `classifyOn`). The pass carries the session
  /// prompt only when the conversation does not hold it, and
  /// `SESSION_CONTEXT_REMOVED` when the prompt is blank. The first pass after
  /// `reset()` carries no copy, because its recap holds the prompt.
  async classify(window: string, covered: string[], earlier: string, context: string): Promise<ClassifyResult> {
    if (this.passes >= this.passLimit) {
      log(`classifier: new conversation after ${this.passes} passes`);
      this.reset();
    }
    const newConversation = this.recapPending;
    this.recapPending = false;
    this.passes++;
    const held = this.lastContext;
    const edited = !newConversation && (held === undefined || context.trim() !== held.trim());
    const result = await classifyOn(this.agent, window, covered, earlier, context, edited);
    if (result.ok) this.lastContext = context;
    else if (edited || newConversation) this.lastContext = undefined;
    return result;
  }

  /// A first turn that pays the cold spawn before a pass needs the agent.
  /// The answer is discarded. After `reset()` it does nothing, because the
  /// first turn of a conversation is the only one that carries the recap.
  async warm(): Promise<TaskResult> {
    if (this.recapPending) return { text: "" };
    return this.agent.run("warm-up", undefined, 15_000);
  }

  /// Drop the conversation. The next pass starts a new one.
  reset(): void {
    this.agent.reset();
    this.passes = 0;
    this.recapPending = true;
  }
}

let cfg: AdvisorConfig | undefined;
let session: ClassifierSession | undefined;

export function configureClassifier(config: AdvisorConfig): void {
  cfg = config;
  session?.reset();
  session = undefined;
}

/// The classifier's session options.
export function classifierOptions(config: AdvisorConfig): AgentSessionOptions {
  return {
    name: "classifier",
    systemPrompt: classifierSystem(config),
    model: modelArg(config),
    allowedTools: [],
    // It only decides what to research; the card lanes do the research. A
    // tool call here held every later trigger back (~10 s instead of ~2 s).
    noTools: true,
    // The classifier only reads the transcript window — it needs none of the
    // user's Claude config, so don't load it on every classify. No effort
    // setting either: it already answers in ~1.5 s, and more thought would
    // only delay every card.
    settingSources: [],
  };
}

function ensureSession(): ClassifierSession {
  if (!session) {
    const config =
      cfg ??
      ({
        triggerSensitivity: "balanced",
        triggers: { question: true, context: true, factcheck: true },
        provider: "claude",
        model: "",
        effort: "",
        allowMcpActions: false,
      } as AdvisorConfig);
    session = new ClassifierSession(createAgent(config.provider, classifierOptions(config)));
  }
  return session;
}

export function resetClassifier(): void {
  session?.reset();
}

/// Pay the SDK subprocess cold-spawn now (at session start) instead of on the
/// first real classification, which sits on the critical path before the first
/// card appears. Best-effort; the warm-up "answer" is discarded.
export async function warmClassifier(): Promise<void> {
  try {
    await ensureSession().warm();
  } catch {
    /* best effort */
  }
}

/// Outcome of one classify pass. `ok:true` is a real result — the classifier ran
/// and returned valid JSON, even if it found nothing (`triggers: []`). `ok:false`
/// is a failure to classify at all: a timeout, a dead session, empty output, or
/// unparseable output. The two were previously conflated as `{triggers: []}`,
/// which let the caller advance its cursor past a window that was never actually
/// judged (issue #43). The caller must only commit the cursor on `ok:true`.
export type ClassifyResult = { ok: true; triggers: Trigger[] } | { ok: false };

/// One classify pass on the classifier session. `earlier` is the end of the
/// conversation before `window`, and `context` is the live session prompt
/// (see `classifyOn`).
export async function classify(window: string, covered: string[], earlier = "", context = ""): Promise<ClassifyResult> {
  return ensureSession().classify(window, covered, earlier, context);
}

/// One classify pass on `session`. `earlier` goes to the session as the recap,
/// so only a pass that starts a new session or thread sends it (#116). A
/// session that keeps its conversation already holds those lines. `context`,
/// the live session prompt, goes into the recap after them, and into the pass
/// when `edited`. So a conversation gets it once, and again after each edit: a
/// copy in every pass grows the conversation by its whole size on each pass.
/// An edit to a blank prompt sends `SESSION_CONTEXT_REMOVED`, so the model
/// drops the old one. By default, only a prompt with text is an edit.
/// It goes through `escapeTags`, as the window and the recap do, so a typed
/// `</earlier>` cannot look like the recap's block.
export async function classifyOn(
  session: Agent,
  window: string,
  covered: string[],
  earlier: string,
  context = "",
  edited = context.trim() !== ""
): Promise<ClassifyResult> {
  const contextBlock = sessionContextPrefix(escapeTags(context));
  const update = edited ? contextBlock || SESSION_CONTEXT_REMOVED : "";
  const prompt = `${update}Already covered: ${covered.join(", ") || "(none)"}

Transcript window (newest last):
${escapeTags(window)}

JSON:`;
  const recap = (earlierBlock(earlier) ?? "") + contextBlock;
  const { text, error } = await session.run(prompt, undefined, 30_000, recap || undefined);
  return parseClassifierResponse(text, error);
}

/// The recap block of a classify pass, or undefined for no earlier lines. A
/// typed note goes into the transcript, so it can be in the recap. A note
/// that holds `</earlier>` ended the block early (#125), so the text goes
/// through `escapeTags`. The text keeps its length, so the bound on the earlier
/// lines (CLASSIFIER_RECAP_CHARS) still holds. The session prompt that follows
/// this block in the recap has no bound.
function earlierBlock(earlier: string): string | undefined {
  if (!earlier) return undefined;
  const text = escapeTags(earlier);
  return `<earlier>\n${text}\n</earlier>\n\n`;
}

/// Pure parse of the classifier's raw turn into a ClassifyResult. Extracted from
/// classify() so the success-vs-failure distinction is unit-testable without the
/// SDK. A set `error` (timeout / dead session), empty text, missing JSON, or a
/// JSON.parse throw all yield `ok:false` (a window to re-judge); valid JSON —
/// including an empty triggers array — yields `ok:true`.
export function parseClassifierResponse(text: string, error?: string): ClassifyResult {
  if (error) {
    log(`classifier turn failed: ${error}`);
    return { ok: false };
  }
  if (!text) {
    log(`classifier returned empty output`);
    return { ok: false };
  }
  const obj = extractFirstJsonObject(text);
  if (!obj) {
    log(`classifier returned no parseable JSON (${text.length} chars)`); // it may quote the transcript
    return { ok: false };
  }
  const enabled = cfg?.triggers ?? { question: true, context: true, factcheck: true };
  const raw = Array.isArray(obj.triggers) ? (obj.triggers as Trigger[]) : [];
  const triggers = raw
    .filter((t) => t && t.kind && t.subject && t.query && enabled[t.kind])
    .slice(0, MAX_TRIGGERS_PER_PASS);
  return { ok: true, triggers };
}

/// Extract the first balanced, brace-delimited JSON object that parses. The
/// classifier is told to emit strict JSON, but LLMs deviate — a prose prefix, a
/// trailing sentence, or a stray second object. The old greedy first-`{`-to-last-
/// `}` slice spanned across all of that into an unparseable string, so a single
/// `}` of trailing junk dropped every trigger for the window (issue #44). Scan
/// for balanced braces instead, then prefer the first object that actually
/// carries a `triggers` array; fall back to the first object that merely parses
/// so a valid-but-triggers-less object still counts as a successful (empty)
/// classification rather than a failure.
function extractFirstJsonObject(text: string): Record<string, unknown> | undefined {
  let fallback: Record<string, unknown> | undefined;
  for (let i = 0; i < text.length; i++) {
    if (text[i] !== "{") continue;
    const candidate = scanBalancedObject(text, i);
    if (candidate === undefined) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(candidate);
    } catch {
      continue;
    }
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      const record = parsed as Record<string, unknown>;
      if (Array.isArray(record.triggers)) return record;
      fallback ??= record;
    }
  }
  return fallback;
}

/// Scan from `start` (which must point at `{`) to its matching close brace,
/// tracking nesting depth. Characters inside a double-quoted string — and the
/// single char following a backslash escape — are skipped, so a `{`, `}`, or `"`
/// inside a JSON string value (e.g. a query containing `}`) never affects the
/// depth count. Returns the inclusive `[start, close]` substring, or undefined
/// if the braces never balance before end of input.
function scanBalancedObject(text: string, start: number): string | undefined {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let j = start; j < text.length; j++) {
    const c = text[j];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return text.slice(start, j + 1);
    }
  }
  return undefined;
}
