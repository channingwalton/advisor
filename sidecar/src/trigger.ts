import { Agent } from "./agent.js";
import { createAgent } from "./providers.js";
import { AdvisorConfig, modelFor } from "./config.js";
import { log } from "./protocol.js";

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

/// The instruction for a follow-up on an existing card. The sidecar is stateless
/// about cards, so the app supplies the card's current body and a recent
/// transcript slice; this reconstructs the context for a transient one-shot
/// session. Mirrors researchTask: single source of truth for the reply prompt.
export function replyTask(
  kind: string,
  title: string,
  cardBody: string,
  followUp: string,
  transcript: string
): string {
  const ctx = transcript.trim()
    ? `\n\nRecent conversation transcript (resolve references like "she"/"that" against it):\n<transcript>\n${transcript.trim()}\n</transcript>`
    : "";
  return (
    `You previously produced this ${kind} card titled "${title}" during a live conversation:\n\n` +
    `<card>\n${cardBody}\n</card>` +
    ctx +
    `\n\nThe user has a follow-up about that card:\n<followup>\n${followUp}\n</followup>\n\n` +
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

function classifierSystem(cfg: AdvisorConfig): string {
  const kinds = (Object.keys(KIND_DESCRIPTIONS) as (keyof AdvisorConfig["triggers"])[])
    .filter((k) => cfg.triggers[k])
    .map((k) => KIND_DESCRIPTIONS[k])
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
- Max ${cfg.maxTriggersPerPass} triggers per message. "subject" is a short dedup key; "query" is a
  self-contained research instruction (include enough context to be understood alone).`;
}

let cfg: AdvisorConfig | undefined;
let session: Agent | undefined;

export function configureClassifier(config: AdvisorConfig): void {
  cfg = config;
  session?.reset();
  session = undefined;
}

function ensureSession(): Agent {
  if (!session) {
    const config =
      cfg ??
      ({
        triggerSensitivity: "balanced",
        triggers: { question: true, context: true, factcheck: true },
        maxTriggersPerPass: 2,
        classifier: { provider: "claude", models: { claude: "haiku" } },
        research: { provider: "claude", models: {} },
        queryAgent: { provider: "claude", models: {} },
        extraInstructions: "",
        allowMcpActions: false,
      } as AdvisorConfig);
    session = createAgent(config.classifier.provider, {
      name: "classifier",
      systemPrompt: classifierSystem(config),
      model: modelFor(config.classifier),
      allowedTools: [],
      // The classifier only reads the transcript window — it needs none of the
      // user's Claude config, so don't load it on every classify.
      settingSources: [],
    });
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
    await ensureSession().run("warm-up", undefined, 15_000);
  } catch {
    /* best effort */
  }
}

export interface ClassifyResult {
  triggers: Trigger[];
  costUsd: number;
}

export async function classify(window: string, covered: string[]): Promise<ClassifyResult> {
  const prompt = `Already covered: ${covered.join(", ") || "(none)"}

Transcript window (newest last):
${window}

JSON:`;
  const { text, costUsd } = await ensureSession().run(prompt, undefined, 30_000);
  if (!text) return { triggers: [], costUsd };

  const match = text.match(/\{[\s\S]*\}/);
  if (!match) {
    log(`classifier returned no JSON: ${text.slice(0, 200)}`);
    return { triggers: [], costUsd };
  }
  try {
    const parsed = JSON.parse(match[0]) as { triggers?: Trigger[] };
    const enabled = cfg?.triggers ?? { question: true, context: true, factcheck: true };
    const triggers = (parsed.triggers ?? [])
      .filter((t) => t.kind && t.subject && t.query && enabled[t.kind])
      .slice(0, cfg?.maxTriggersPerPass ?? 2);
    return { triggers, costUsd };
  } catch (err) {
    log(`classifier JSON parse failed: ${err}`);
    return { triggers: [], costUsd };
  }
}
