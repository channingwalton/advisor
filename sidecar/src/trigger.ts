import { AgentSession } from "./agent.js";
import { log } from "./protocol.js";

export interface Trigger {
  kind: "question" | "context" | "factcheck";
  subject: string;
  query: string;
}

const CLASSIFIER_SYSTEM = `You are the trigger detector for a proactive realtime meeting
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
BEFORE being asked. In an active, substantive conversation you should produce a trigger
every minute or two. Returning {"triggers":[]} constantly means you are failing. Only
stay silent for pleasantries, chit-chat, or meta-talk about this app.

Reply to EVERY message with STRICT JSON only, no prose, no markdown:
{"triggers":[{"kind":"question","subject":"...","query":"..."}]}

kind is one of:
- "question": a factual question asked or wondered aloud (incl. implicit/musing forms:
  "I wonder", "not sure what", "does anyone know", "how does X work") that the transcript
  doesn't answer. ALWAYS trigger on these. This INCLUDES personal questions about the
  user's own notes, vault, projects, or work history ("what did I change in X", "when did
  I last...", "what's in my notes about...") — the research agent can search the user's
  Obsidian vault, so these are among the MOST valuable triggers.
- "context": a named project, system, person, company, product, acronym, ticket, or topic
  is being discussed where background, definitions, or recent news would help a
  participant. Unfamiliar terms and acronyms are prime candidates. Also use this when a
  topic is discussed at length and useful data exists (e.g. they debate costs → fetch the
  actual numbers).
- "factcheck": a specific checkable claim was stated as fact (numbers, dates,
  capabilities, "X said/does Y") and verifying it would add value.

Rules:
- Reassembled-sentence questions count even if split across lines.
- Skip anything whose subject is in the "already covered" list of the message.
- Max 2 triggers per message. "subject" is a short dedup key; "query" is a
  self-contained research instruction (include enough context to be understood alone).`;

const session = new AgentSession({
  name: "classifier",
  systemPrompt: CLASSIFIER_SYSTEM,
  model: "haiku",
  allowedTools: [],
});

export function resetClassifier(): void {
  session.reset();
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
  const { text, costUsd } = await session.run(prompt, undefined, 30_000);
  if (!text) return { triggers: [], costUsd };

  const match = text.match(/\{[\s\S]*\}/);
  if (!match) {
    log(`classifier returned no JSON: ${text.slice(0, 200)}`);
    return { triggers: [], costUsd };
  }
  try {
    const parsed = JSON.parse(match[0]) as { triggers?: Trigger[] };
    const triggers = (parsed.triggers ?? [])
      .filter((t) => t.kind && t.subject && t.query)
      .slice(0, 2);
    return { triggers, costUsd };
  } catch (err) {
    log(`classifier JSON parse failed: ${err}`);
    return { triggers: [], costUsd };
  }
}
