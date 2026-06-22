# Advisor — Requirements

**Status:** Draft v1 — 2026-06-11
**Owner:** Channing

## Vision

A personal macOS tool that listens to conversations in realtime (calls, in-person, any system audio), understands what's being discussed, and quietly surfaces answers, context, and fact-checks within seconds — drawing on the web, the Obsidian Vault, work tools, and local files.

## Functional requirements

### Capture
- F1. Capture microphone audio (in-person conversations).
- F2. Capture system audio (Zoom/Meet/Teams or anything else playing) without a meeting bot.
- F3. Run both simultaneously, distinguishing "me" (mic) from "them" (system audio).
- F4. Start/stop listening with one action; clear visual indicator when live.

### Understanding
- F5. Stream speech to text continuously with low latency.
- F6. Detect, in the transcript stream:
  - questions asked aloud,
  - entities/topics warranting background context (projects, people, tickets, technologies),
  - factual claims worth verifying.
- F7. Maintain rolling conversation context so retrieval is topic-aware, not utterance-by-utterance.

### Answering
- F8. Answer detected questions automatically.
- F9. Surface background context for detected entities (relevant notes, tickets, docs, prior discussion).
- F10. Fact-check claims against web/internal sources, citing the source; say "couldn't verify" rather than guess when a claim can't be confirmed.
- F11. Search across: web, Obsidian Vault (`~/Documents/Notes`), work tools via MCP (Jira, Confluence, Slack), local files/repos.
- F12. Every answer cites its source(s).

### Interface
- F13. Live sidebar/overlay: floating, always-on-top, compact; updates as conversation flows; never steals focus.
- F14. On-demand query: a text box to ask about the current conversation or anything else, with conversation transcript as context.
- F14a. In-situ actions: right-click selected transcript text to run an action (Answer / Context / Fact check) on it — the same kinds the auto-classifier detects, gated by the same per-kind toggles; the resulting card is anchored under the originating line.
- F15. Show live transcript (collapsible).
- F16. Session history: transcripts and surfaced items reviewable afterwards, stored as app-managed local markdown files. No writing to the Obsidian Vault (read-only source).
- F17. Session tags (issue #15): a user-managed library of coloured tags (Preferences), applied to a session from the live toolbar or the browser, shown as coloured pills on session rows and searchable. Stored by name in the note's frontmatter.

## Non-functional requirements

- N1. **Latency:** best efforts; ~2–5 s after the triggering utterance is the aspiration, not a hard requirement (relaxed 2026-06-11).
- N2. **Platform:** macOS only (Apple Silicon).
- N3. **Privacy:** STT runs on-device (Apple SpeechAnalyzer); only text leaves the machine. Listening must be explicitly user-initiated.
- N4. **Cost:** STT is local (free); LLM cost per listening-hour must be tolerable for daily personal use.
- N5. **Single user:** no auth, multi-tenancy, or deployment concerns.
- N6. **Reliability:** capture pipeline must not drop audio during long sessions (1 h+).

## Architecture decision: MCP server vs standalone

**Recommendation: standalone macOS app, with MCP used as the *client* protocol for sources.**

| Option | Verdict |
|---|---|
| **MCP server** | Wrong shape. MCP is request/response invoked by a host (Claude/Cowork). It cannot capture audio continuously or push proactive UI updates. An "Advisor MCP server" would need something else doing the listening anyway. |
| **Standalone app (recommended)** | Owns the audio pipeline, the always-on agent loop, and the overlay UI. Uses the Claude Agent SDK (or direct API) as the brain, which itself connects to Jira/Confluence/Slack/filesystem *as an MCP client* — so all sources come free via existing connectors. |
| **Hybrid (later)** | The standalone app can additionally expose an MCP server ("search my past conversations") so Claude/Cowork can query Advisor's transcripts. Nice follow-on, not v1. |

## Proposed shape (to validate in design phase)

```
mic ──┐
      ├─ audio capture (ScreenCaptureKit / AVAudioEngine)   ─┐
sys ──┘        │                                             │
        local streaming STT (Apple SpeechAnalyzer)           ├─ Swift app
               │                                             │
        trigger detection (question? entity? claim?)         │
               │                                            ─┘
        research agent (Claude Agent SDK: web search,       ─── TS sidecar
               Vault read-only, MCP connectors)                 (local IPC)
               │
        overlay UI (NSPanel sidebar + query box) + session store (markdown)
```

Two-tier latency strategy: a fast classifier decides *whether* to act (<1 s); the research agent then has the remaining budget to retrieve and answer.

## Risks / open issues

- **Consent & legality:** recording calls may require participant consent depending on jurisdiction. App should make recording status obvious; storing audio vs transcript-only TBD.
- **Echo/duplication:** own voice may appear in both mic and system audio during calls.
- **Trigger precision:** too sensitive → noisy sidebar; too conservative → useless. Needs tuning loop.
- **Fact-check hallucination:** must show sources and degrade to "couldn't verify" rather than guess.
- **Vault search:** needs an indexing approach (ripgrep-on-demand vs embedding index) — decide in design.

## Out of scope (v1)

- Meeting bots joining calls; speaking into the call; team/multi-user features; mobile; Windows/Linux.

(Post-meeting summaries were originally out of scope but added in issue #30 — an
on-demand Summarise control on the live and saved-session views. See DESIGN.md.)

## Decided (2026-06-11)

- **Stack:** native Swift/SwiftUI app (capture, local STT, overlay UI) + TypeScript sidecar running the Claude Agent SDK for search/reasoning, over local IPC.
- **STT:** local Whisper on Apple Silicon (whisper.cpp or MLX). Latency budget must accommodate this — needs early prototyping (N1 risk).
- **Storage:** transcripts only, no audio recordings.
- **Output:** app-managed local markdown files; the Obsidian Vault is read-only.

## Changed (2026-06-14)

- **STT:** dropped whisper.cpp entirely; Apple SpeechAnalyzer is now the only engine. It needs no model download, no vendored build, and hallucinates far less on noise. Supersedes the 2026-06-11 Whisper decision above.
