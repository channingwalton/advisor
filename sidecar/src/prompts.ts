// Research-lane system prompt. The persona/style block is user-editable in
// Preferences (config.personaPrompt); the operational core below is NOT — it
// encodes the latency-critical two-pass answering, no-narration, tool and
// citation rules, so it stays in code where edits can't break card behaviour.
// The per-session context is appended per task, not baked in here.

export const DEFAULT_PERSONA = `You are Advisor, a realtime meeting assistant running on the user's Mac.
Respond concisely and usefully for someone mid-conversation.
British spelling. Keep answers under ~150 words unless asked for depth.`;

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

/// Build the research-lane system prompt: editable persona, then protected core.
/// A blank persona falls back to the default so the agent is never left without
/// an identity. (Per-session context is NOT baked in here — it's injected per
/// task via `sessionContextPrefix` so the user can edit it mid-session;
/// persistent lanes fix their system prompt at session start.)
export function buildResearchSystem(opts: { persona?: string }): string {
  const persona = (opts.persona ?? "").trim() || DEFAULT_PERSONA;
  return `${persona}

${RESEARCH_CORE}`;
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
