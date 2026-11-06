# Advisor — Requirements

**Status:** Living document — last revised 2026-11-06 (first draft 2026-06-11).
Decision history is in [DESIGN.md](DESIGN.md).
**Owner:** Channing

## Vision

A personal macOS tool that listens to conversations in realtime (calls, in-person, any system audio), understands what's being discussed, and quietly surfaces answers, context, and fact-checks within seconds — drawing on the web, work tools, and the user's own notes and local files.

## Functional requirements

### Capture
- F1. Capture microphone audio (in-person conversations).
- F2. Capture system audio (Zoom/Meet/Teams or anything else playing) without a meeting bot.
- F3. Run both simultaneously, distinguishing "me" (mic) from "them" (system audio).
- F4. Start/stop listening with one action; clear visual indicator when live.
  - A microphone permission denial leaves a working retry in the same Recording window (issue #83). `#recording-retry-permission`
  - An initial speech-engine failure leaves a working retry without replacing the session note. `#recording-retry-start`
  - Failed speech recovery leaves Resume available and preserves existing transcript and note ownership. `#recording-retry-recovery`
- F4a. Mute the microphone mid-session with one action; system audio keeps being captured and transcribed until unmuted.

### Understanding
- F5. Stream speech to text continuously with low latency.
  - Meaningful short microphone replies survive when system capture is enabled but has no matching speech (issue #80). `#echo-short-replies`
  - Matching system speech still suppresses microphone echoes, including exact short replies. `#echo-matching-speech`
- F5a. The speech-recognition locale is chosen in Preferences from those the on-device engine supports, defaulting to the system locale; a change applies at the next Listen.
- F6. Detect, in the transcript stream:
  - questions asked aloud,
  - entities/topics warranting background context (projects, people, tickets, technologies),
  - factual claims worth verifying.
- F6a. Trigger sensitivity (conservative / balanced / eager) and a toggle per kind (answer / context / fact-check), set in Preferences, tune how readily cards appear.
- F7. Maintain rolling conversation context so retrieval is topic-aware, not utterance-by-utterance.
  - A research or query lane whose session lost the conversation, after a failed card, a cancelled Codex card or a Claude CLI that stopped between cards, is sent the whole conversation again, so its next card keeps the earlier context (issues #112, #126). `#context-lane-recycle`
  - When the trigger classifier's session or thread starts again, its next classification is sent the recent conversation as context, so a new line keeps its referent; a session that kept the conversation is not sent it again (issue #116). `#classifier-recap`
- F7a. Session context: an optional name (titling the session in the browser) and session prompt (who's present, the topic, what to focus on), set before Listen or edited live; each edit steers the agents from the next card. Both clear when the session ends.
  - A question asked after a session ends, before the next Listen, carries neither that session's prompt nor its conversation (issue #113). `#session-prompt-end`
- F7b. Saved contexts (issue #10): a library of named contexts, managed in Preferences, that can be loaded into a session's context, or saved from it, instead of retyping common setups.

### Answering
- F8. Answer detected questions automatically.
  - Turning Auto cards off starts no further automatic card: a classification still running or waiting, and research waiting for a lane, are dropped (dropped subjects can come up again). `#auto-off-stops-cards`
  - Turning Auto cards back on classifies only what is said from then on. `#auto-resume-new-speech`
  - A detected subject in any script (not only Latin) produces a card, and is deduplicated as itself. `#trigger-subject-any-script`
- F8a. Auto cards: one toolbar toggle turns automatic cards (answers, context, fact-checks) off and on mid-session without stopping listening; manual actions and Ask keep working while it's off.
- F9. Surface background context for detected entities (relevant notes, tickets, docs, prior discussion).
- F10. Fact-check claims against web/internal sources, citing the source; say "couldn't verify" rather than guess when a claim can't be confirmed.
- F11. Search across: the web, work tools via the user's MCP connectors (e.g. Jira, Confluence, Slack), and the user's own notes and local files/repos (read-only; credential paths excluded). A Codex card cannot search local files itself (N12): it reaches notes only through a connector. Advisor holds no notes location of its own: personal context, such as where notes live, comes from the user's own agent configuration (for Claude, `~/.claude/CLAUDE.md`).
- F12. Every answer cites its source(s).

### Agent backend
- F12a. Choose the agent backend in Preferences — Claude (Agent SDK) or Codex — with a model; one choice serves every agent lane (classifier, research, query).
- F12b. Authentication defaults to the chosen provider's CLI subscription login; an API key is never required. An opt-in API-key mode takes an Anthropic or OpenAI key, kept in the macOS Keychain (never in the config file) and checked with the provider when entered.
- F12c. Effort (Claude only): a preference sets how much Claude thinks before answering — Default (the user's own Claude Code setting) or Low through Max — trading card speed for depth. It applies to every card, follow-up, Ask and Summarise, not to the trigger classifier.

### Interface
- F13. Live recording window: compact; updates as the conversation flows without stealing focus; can be kept on top of other windows on request (Float).
  - Float off gives the window back the collection behaviour that it had before Float, such as `.auxiliary` (issue #130).
  - After a close and a reopen, Float and the recording window agree: the window floats while Float shows on (issue #132).
- F14. On-demand query: Ask (a toolbar popover, ⌘K) about the current conversation or anything else, with conversation transcript as context.
  - An Ask or a right-click action while another runs gets its own card at once, within a cap on busy query lanes (three, plus a fresh lane after a session start); one past the cap gets a failed card that holds the question, never a silent refusal (issue #110). `#query-busy`
- F14a. In-situ actions: right-click selected transcript text to run an action (Answer / Context / Fact check) on it — the same kinds the auto-classifier detects, gated by the same per-kind toggles; the resulting card is anchored under the originating line.
- F14b. Editorial notes (issue #34): right-click a transcript line to inject the user's own context as a distinct green NOTE card anchored at that line; the agents read it as part of the transcript (so it can inform or trigger research). Deletable; persisted with the session.
  - The toolbar's Note (⇧⌘N) adds one at the current point in the conversation, or at the end of a saved transcript; right-click opens the same popover placed at its line (issue #104).
  - A note added before Listen is kept when the session starts, opens its transcript, and reaches the agents once the session has started (issue #104).
  - A note that holds the tag of a prompt block, such as `</transcript>` or `<earlier>`, stays inside that block, and so do the lines after it (issues #125, #128, #129). `#note-in-block`
  - A question asked before Listen keeps its card when the session starts, and an answer still being written then finishes (issue #104).
- F14c. Transcript corrections (issue #32): right-click a mis-transcribed word or phrase to correct that instance or replace it throughout the session, live or in a saved session; the correction is saved to the transcript in place.
- F14d. Card follow-ups: a finished card takes a follow-up question, whose answer is appended to that card, so a card becomes a short thread.
  - A card body that holds `</card>`, or a follow-up that holds `</followup>`, stays inside its block of the follow-up prompt (issue #131). `#followup-in-block`
- F14e. Summarise (issue #30): on demand, live or on a saved session, distil the whole conversation into one Summary card kept with the note; summarising again updates it in place.
- F15. Show live transcript (collapsible).
- F16. Session history: transcripts and surfaced items reviewable afterwards, stored as app-managed local markdown files. Agents never write to the user's notes or other files (read-only sources).
  - The saved note keeps a card's last completed answer while a follow-up or re-summarise runs, and after one is cancelled. `#card-settled-note`
  - A failed re-summarise keeps the previous summary, in the window and the note. `#card-settled-summary`
  - An Ask answer or Summary for a saved note still saves if the note is filed into a folder meanwhile, and a deleted note is never recreated. `#saved-note-moved-save`
  - An Ask or Summarise on a saved note can be stopped while it runs; nothing is saved, and a stopped question returns to the Ask popover. `#sessions-answer-cancel`
- F16a. Ask a saved session: a question about a past session is answered from its note, and the answer is appended to that note under a Follow-ups heading.
- F16b. Manage saved sessions: rename (a short name titles the session in the list; blank falls back to its context), export a copy of the markdown, share it, open it in the default Markdown app (issue #127), reveal it in Finder, or delete it behind a confirmation. The live session can be exported from the recording window, but not deleted or opened in another app.
- F16c. Session folders (issues #25, #35): organise sessions into user-named folders in the browser; file a session by dragging it onto a folder or with Move to Folder, and start a recording straight into a folder. Deleting a folder keeps its sessions.
- F16d. Folder context (issue #36): a folder can hold a context that seeds the session prompt of every recording started in it, editable per session; it can be loaded from a saved context (F7b).
- F17. Session tags (issue #15): a user-managed library of coloured tags (Preferences), applied to a session from the live toolbar or the browser, shown as coloured dots on session rows (and pills in the session detail) and searchable. Stored by name in the note's frontmatter.
- F17a. Folder tag defaults (issue #76): folders can hold tags from the library; a new recording started from that folder inherits them, with per-session editing still available. Existing sessions and sessions moved into the folder are unchanged.
- F17b. Owned session folders (issue #78):
  - Rename and delete are blocked while a folder contains a recording's owned note, including while stopped; subsequent transcript and cards remain saved. `#folder-owned-preserved`
  - Other folders remain editable, and the protected folder becomes editable once the writer releases its note. `#folder-owned-released`
- F18. Closing Recording (issue #79):
  - Save final microphone text already waiting for echo detection before releasing the note. `#close-mic-delay`
  - Save finals emitted while speech engines finish, retaining note ownership until the final save. `#close-speech-finals`
  - Retire the old generation only after saving; late old results cannot enter a reopened session. `#close-generation-isolation`
  - Quitting (⌘Q) saves the same tail — echo-delayed microphone text and finals emitted while the engines stop — before exiting. `#quit-saves-tail-finals`
  - Quitting still exits if speech teardown hangs, after a deadline, and saves the note first. `#quit-deadline`

## Non-functional requirements

- N1. **Latency:** best efforts; ~2–5 s after the triggering utterance is the aspiration, not a hard requirement (relaxed 2026-06-11).
  - A card's answer appears as the agent writes it, not when the agent finishes. `#card-token-stream`
  - While a card researches, it shows what the agent is doing (searching the web, reading a file, thinking); the line goes once the answer is being written or the card ends. `#card-activity`
  - The trigger classifier only decides what to research: it is offered no tools, built-in or connector, so it never searches or reads itself. (On Codex, a few built-ins no setting removes are still offered — plan, ask the user, view an image and, for some models, patch and search tools — and each is inert there.) `#classifier-no-tools`
- N2. **Platform:** macOS only (Apple Silicon).
- N3. **Privacy:** STT runs on-device (Apple SpeechAnalyzer); only text leaves the machine, and no audio is stored. Listening must be explicitly user-initiated.
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
- N10. **Codex connectors:**
  - Codex can't refuse a connector call by what it does, so without "Allow connector actions" a Codex card lane is offered no connectors: none of the MCP servers or plugins in `~/.codex/config.toml`, and no ChatGPT apps. With it, it has them all, as on Claude. `#codex-connectors`
- N11. **Hang diagnostics:**
  - When a ping to the main thread stays unanswered for 5 s, the app logs the stall and its length and saves one stack sample of itself in the logs folder. The app pings once a second, so a stall of about 7 s or more is caught, and a delayed timer (App Nap) can make it later. The length counts from the unanswered ping, not from the start of the stall. A long stall gives one sample, and the app logs when the main thread answers again. `#stall-sample`
  - The logs folder keeps the newest five stack samples. `#stall-sample-cap`
  - When the user closes the recording window (close button or ⌘W), the app logs whether agent tasks were running, the first responder of each visible window and, when the prompt appears, the choice. A close while the window is already finishing is ignored and not logged. `#close-log`
- N12. **Codex shell (issue #118):**
  - Under the Seatbelt profile, a Codex card lane runs no shell command: the CLI cannot apply its own sandbox inside the profile, so a command fails before it reads an ordinary file or a denied path (such as `~/.ssh`). The user guide says that Codex cards cannot run shell commands. `#codex-shell`

## Risks

- **Consent and legality:** in some jurisdictions, the recording of a call needs the consent of each participant. The app must make the recording status obvious. Advisor stores transcripts only, no audio.
- **Echo and duplication:** the user's own voice can reach both the mic and the system audio during a call.
- **Trigger precision:** a classifier that is too sensitive fills the feed with noise, and one that is too conservative gives no value. It needs a tuning loop.
- **Fact-check hallucination:** a fact-check must show its sources, and say "couldn't verify" rather than guess.

## Out of scope (v1)

- Meeting bots that join calls, and speech into the call.
- Team and multi-user features.
- Mobile, Windows and Linux.
- An MCP server over past sessions, so that a host such as Claude can query Advisor's transcripts. It is a possible later addition: see *Revisit as it grows* in DESIGN.md.
