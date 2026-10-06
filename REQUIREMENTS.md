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
  - A microphone permission denial leaves a working retry in the same Recording window (issue #83). `#recording-retry-permission`
  - An initial speech-engine failure leaves a working retry without replacing the session note. `#recording-retry-start`
  - Failed speech recovery leaves Resume available and preserves existing transcript and note ownership. `#recording-retry-recovery`

### Understanding
- F5. Stream speech to text continuously with low latency.
  - Meaningful short microphone replies survive when system capture is enabled but has no matching speech (issue #80). `#echo-short-replies`
  - Matching system speech still suppresses microphone echoes, including exact short replies. `#echo-matching-speech`
- F6. Detect, in the transcript stream:
  - questions asked aloud,
  - entities/topics warranting background context (projects, people, tickets, technologies),
  - factual claims worth verifying.
- F7. Maintain rolling conversation context so retrieval is topic-aware, not utterance-by-utterance.
  - A research or query lane restarted after a failed card is sent the whole conversation again, so its next card keeps the earlier context. `#context-lane-recycle`

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
- F14b. Editorial notes (issue #34): right-click a transcript line to inject the user's own context as a distinct green NOTE card anchored at that line; the agents read it as part of the transcript (so it can inform or trigger research). Deletable; persisted with the session.
- F15. Show live transcript (collapsible).
- F16. Session history: transcripts and surfaced items reviewable afterwards, stored as app-managed local markdown files. No writing to the Obsidian Vault (read-only source).
  - The saved note keeps a card's last completed answer while a follow-up or re-summarise runs, and after one is cancelled. `#card-settled-note`
  - A failed re-summarise keeps the previous summary, in the window and the note. `#card-settled-summary`
- F17. Session tags (issue #15): a user-managed library of coloured tags (Preferences), applied to a session from the live toolbar or the browser, shown as coloured pills on session rows and searchable. Stored by name in the note's frontmatter.
- F17a. Folder tag defaults (issue #76): folders can hold tags from the library; a new recording started from that folder inherits them, with per-session editing still available. Existing sessions and sessions moved into the folder are unchanged.
- F17b. Owned session folders (issue #78):
  - Rename and delete are blocked while a folder contains a recording's owned note, including while stopped; subsequent transcript and cards remain saved. `#folder-owned-preserved`
  - Other folders remain editable, and the protected folder becomes editable once the writer releases its note. `#folder-owned-released`
- F18. Closing Recording (issue #79):
  - Save final microphone text already waiting for echo detection before releasing the note. `#close-mic-delay`
  - Save finals emitted while speech engines finish, retaining note ownership until the final save. `#close-speech-finals`
  - Retire the old generation only after saving; late old results cannot enter a reopened session. `#close-generation-isolation`

## Non-functional requirements

- N1. **Latency:** best efforts; ~2–5 s after the triggering utterance is the aspiration, not a hard requirement (relaxed 2026-06-11).
- N2. **Platform:** macOS only (Apple Silicon).
- N3. **Privacy:** STT runs on-device (Apple SpeechAnalyzer); only text leaves the machine. Listening must be explicitly user-initiated.
- N4. **Cost:** STT is local (free); LLM cost per listening-hour must be tolerable for daily personal use.
- N5. **Single user:** no auth, multi-tenancy, or deployment concerns.
- N6. **Reliability:** capture pipeline must not drop audio during long sessions (1 h+).
- N7. **Claude credential sandbox (issue #77):**
  - Denied credential paths remain unreadable through both symlink aliases and their resolved targets. `#sandbox-symlink-read`
  - Recursive searches reject roots containing a resolved denied path. `#sandbox-symlink-search`
  - Ordinary files remain readable, and scoped searches without denied descendants remain permitted. `#sandbox-symlink-permitted`
  - Denied paths stay unreadable through the real CLI, including reads the SDK would approve before `canUseTool` (inside the working directory, or by an allow rule in the user's settings). `#sandbox-sdk-gate`
  - A search pattern cannot redirect a search outside its checked root (absolute, `~` and `..` patterns are refused). `#sandbox-glob-pattern`
  - Only web, ToolSearch, read/search and gated connector tools run; every other tool is refused. `#sandbox-tool-allowlist`
  - File tools take absolute or `~` paths (not relative ones), so the policy judges the file the CLI opens. `#sandbox-explicit-paths`
- N8. **Codex session ordering (issue #81):**
  - Warm-ups and requests execute FIFO per session, preserving initial instructions and the conversation thread on later requests. `#codex-session-fifo`
  - Reset cancels active and queued work; subsequent requests start fresh and ignore late events from abandoned turns. `#codex-session-reset`
  - Explicit cancellation settles active and queued work without dispatching queued requests; abandoned output cannot reach later cards. `#codex-session-cancel`
  - Failed startup or turns release the queue and retry with configured instructions. `#codex-session-recovery`
- N9. **Sidecar authentication (issue #82):**
  - The next recording session applies the selected authentication mode and current provider key, including key replacements and provider changes. `#sidecar-auth-refresh`
  - Subscription mode removes both provider API-key overrides from the child environment. `#sidecar-auth-subscription`
  - Unchanged effective authentication reuses the existing sidecar. `#sidecar-auth-stable`
  - Late termination, output and retry callbacks from a replaced sidecar cannot affect its replacement. `#sidecar-auth-generation`

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
