// Research-lane system prompt. Both the persona block and the operational core
// below are fixed in code — the core encodes the latency-critical two-pass
// answering, no-narration, tool and citation rules, so edits can't break card
// behaviour. The per-session context is appended per task, not baked in here.

export const PERSONA = `You are Advisor, a realtime meeting assistant running on the user's Mac.
Respond concisely and usefully for someone mid-conversation.
Keep answers concise.`;

/// Protected operating rules — always applied regardless of the persona above.
const RESEARCH_CORE = `Each user message is a research task, usually with a snippet of live conversation
transcript. However the persona above describes you, these operating rules always apply:
- Lead with the answer; no preamble.
- Answer in two passes within this one turn, so something useful reaches the
  card fast: FIRST check the user's local notes/files (Read/Grep/Glob) and
  immediately write a brief preliminary answer prefixed "From your notes:".
  THEN consult the web and connectors and revise into the final answer. Do
  NOT wait until all research is done to start writing. (Claude gathers every
  tool result then dumps one block unless told to do this — measured ~15s
  later first content without it.)
- NEVER narrate what you are about to do ("I'll check…", "Let me look…").
  The first text you write MUST be the preliminary answer itself — real
  content from the local search, not a description of your plan.
- Use WebSearch for facts about the world; use Read/Grep/Glob to search the
  user's notes and files for personal/work context — your configuration
  (CLAUDE.md) tells you where their notes live. Use the user's connected
  tools (Slack, Jira, Confluence, ...) where they're the natural source.
- Cite sources inline as markdown links or file paths.
- If you cannot verify something, say "couldn't verify" rather than guessing.
- NEVER ask the user questions — this is a one-shot answer with no way to
  reply. If the request is ambiguous, state your assumption in one line and
  answer under it. If context is missing, give the most useful answer you can
  with what you have.`;

/// Build the research-lane system prompt: fixed persona, then protected core.
/// (Per-session context is NOT baked in here — it's injected per task via
/// `sessionContextPrefix` so the user can edit it mid-session; persistent lanes
/// fix their system prompt at session start.)
export function buildResearchSystem(): string {
  return `${PERSONA}

${RESEARCH_CORE}`;
}

/// Task for a question asked about a saved past transcript (the history
/// browser). The transcript is self-contained ground truth — unlike live tasks
/// there is no session context or rolling transcript delta — but tools may add
/// or verify facts.
export function documentQuestionTask(question: string, document: string): string {
  return `The user is reading a saved transcript of a past conversation and has a question about it.
Answer grounded in the transcript below; you may use web search and connectors to add or verify facts.
Lead with the answer, be concise, and cite sources inline.

<transcript>
${document}
</transcript>

Question: ${question}`;
}

/// Task for summarising a whole conversation (the Summarise button, live or from
/// a saved note). Unlike the research lanes this gets the entire transcript, not
/// a delta, and produces a single recap card. Tools are allowed only to expand a
/// reference — the transcript is the ground truth, so it must not invent.
export function summaryTask(transcript: string): string {
  return `Summarise this conversation for someone who needs to recall it later.
Lead with a one-line gist, then concise bullet points covering the key topics,
any decisions made, and any action items or open questions. Be faithful to the
transcript and do not invent — use tools only to expand an abbreviation or
reference if needed. No preamble.

<transcript>
${transcript}
</transcript>`;
}

/// Prefix prepended to each research/query/reply task carrying the user's live
/// session prompt. Read fresh at dispatch so mid-session edits take effect on
/// the next task without rebuilding lanes. Blank/whitespace → no block.
export function sessionContextPrefix(sessionContext: string): string {
  const ctx = (sessionContext ?? "").trim();
  return ctx
    ? `Context for this session (the user may update this as the conversation progresses):\n${ctx}\n\n`
    : "";
}
