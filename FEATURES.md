# Advisor — Features

A personal macOS assistant that listens to live conversations, transcribes
them on-device, and proactively surfaces answers, context, and fact-checks as
you talk.

## Live listening

- **Listens to any conversation** — meetings, calls, videos, or in-person
  chats. One **Listen** button starts it; a clear indicator shows when it's
  live.
- **Captures both sides** — your microphone (you) and your Mac's system audio
  (everyone else, via ScreenCaptureKit) at once, with no meeting bot joining
  the call.
- **Mic mute** — silence your own microphone mid-session while system audio
  keeps being captured and transcribed; tap again to unmute.
- **Echo dedup** — removes your own voice when it bleeds from the speakers back
  into the mic during calls, so it isn't transcribed twice.

## On-device transcription

- **Live transcript** — words appear in grey as they're spoken and firm up into
  finalised sentences, shown as a clean chronological feed.
- **On-device speech-to-text** — uses Apple SpeechAnalyzer (macOS 26+). Audio
  never leaves your Mac; only text is ever sent anywhere.
- **No audio kept** — nothing is recorded. Only the transcript is stored.
- **Locale-aware** — choose the speech recognition locale in Preferences.

## Proactive assistance

As the conversation flows, Advisor decides what's worth helping with and
surfaces a card inline, anchored to the moment it relates to:

- **Answers** — questions asked aloud are answered automatically.
- **Context** — background on the people, projects, tickets, and technologies
  being discussed.
- **Fact-checks** — claims are checked against sources, saying "couldn't
  verify" rather than guessing when a claim can't be confirmed (fact-check
  cards start collapsed to stay out of the way).
- **Cited sources** — cards cite their sources inline, as links or file paths.
- **Tunable triggers** — set sensitivity (conservative / balanced / eager) and
  toggle each card kind (answer / context / fact-check) on or off.
- **Two-tier speed** — a fast classifier decides *whether* to act in under a
  second, leaving the research agent the rest of the budget to answer
  (aspiration: a useful card within a few seconds).
- Choose AI provider: Claude/Codex subscription/API

## Ask anything

- **Query box** — ask a question at any time, about the current conversation or
  anything else; the live transcript is used as context.
- **Right-click transcript actions** — select any transcript text and run
  **Answer / Context / Fact check** on it directly — the same actions the
  assistant triggers automatically — with the card anchored under that line.
  The menu also copies the selected text.
- **Card follow-ups** — once a card is done, ask a follow-up on it and the
  reply is appended in place, turning a card into a short thread.
- **Card controls** — collapse, expand, or dismiss any card; dismissing one
  that's still researching cancels its work.

## Recording window

- **Floating mode** — keep the window always-on-top so it sits beside your call
  without stealing focus.
- **Resumable stop** — **Stop** pauses capture but keeps the session live;
  **Resume** picks it back up with full context. The session is finalised when
  the window closes.
- **Session context prompt** — set who's present, the topic, and what to focus
  on before you start, or edit it live to steer the assistant; each change
  applies to the next card.
- **Export** — copy the current session note to a location you choose.

## Sessions browser

The app opens on a master/detail browser of your past sessions:

- **Grouped & searchable list** — sessions grouped by day (Today / Yesterday /
  Earlier this week / …), with search, an All / This week filter, and a
  recent / oldest sort toggle. Each row shows a title, a gist, duration, and
  card count.
- **Full session detail** — title and meta, the questions you asked, and the
  transcript rendered just like the live window, with the surfaced cards
  inline.
- **Ask-and-append** — ask a question about a past session; the answer streams
  in and is appended to that session's note under a **Follow-ups** heading, so
  the saved transcript grows with the questions you ask of it.
- **Rename, export, reveal & delete** — give a session a short name for an
  easier-to-scan list, export a copy of its markdown, reveal its markdown file
  in Finder, or delete it (behind a confirmation). Available from the detail
  header's `…` menu and from each list row's right-click menu.

## Organisation

- **Tags** — a user-managed library of coloured tags. Apply them from the live
  toolbar or the browser; they show as coloured pills on session rows and are
  searchable (type `#tag` to filter). Renaming a tag updates it everywhere.
- **Saved contexts** — pre-canned context prompts you can pick from instead of
  retyping common setups to use to guide a recording session.
- **Markdown sessions** — every session is saved as a portable markdown file
  with cards embedded inline, in a folder you choose.

## Sources

Advisor researches across whatever you've connected:

- **Web search** — built in.
- **Your notes & connectors** — your local file system, work tools such as Jira,
  Confluence, Slack, etc. as configured in your AI connectors, read-only by default, independent of Advisor
- **Local files** — read-only access to non-sensitive files in your home
  directory.

## Privacy & safety

- **Local-first** — STT is on-device; listening is always explicitly
  user-initiated.
- **Sandboxed research (Claude)** — a per-call tool policy allows web search,
  read/search-only connectors, and read-only home-directory access. No shell,
  no writes. Credential paths (`~/.ssh`, `~/.aws`, `~/.claude`, keychains, …)
  are denied — case-insensitively, with symlinks resolved so a link can't slip
  past the denylist.
- **Sandboxed research (Codex)** — coarser, because the Codex SDK has no
  per-call hook: a process-wide `read-only` sandbox with `never` approval blocks
  all writes and escalation, but read-only shell *is* permitted (so the
  credential-path denylist does not apply), and MCP connectors come from your
  `~/.codex/config.toml` rather than the "Allow connector actions" gate.
- **Connectors fail closed (Claude)** — anything not recognised as a read or
  search is treated as an action and gated behind an opt-in "Allow connector
  actions" toggle.
- **Single user** — no accounts, no multi-tenancy, no server. Everything runs
  locally.

## Providers & authentication

- **Choice of brain** — every agent lane (classifier, research, query) shares
  one backend: **Claude** (Agent SDK) by default, or **Codex**
  (`@openai/codex-sdk`), picked in Preferences.
- **Uses your existing login** — defaults to your Claude Code / Codex CLI
  subscription.
- **Optional API-key fallback** — for a machine with no CLI login, paste an
  Anthropic or OpenAI key (stored in the macOS Keychain). The
  key is validated against the provider when entered, so a bad key surfaces
  immediately.

## Preferences & appearance

- **Settings** (⌘,) — parallel agent count, connector permissions, trigger
  sensitivity and per-kind toggles, agent backend and model, saved contexts,
  the tag library, system-audio capture, STT locale, and the session storage
  folder.
- **Appearance** — system, light, or dark.

## Packaging

- **Self-contained app** — `package.sh` builds a self-contained, ad-hoc-signed
  `Advisor.app` bundling the Node runtime and sidecar. Node isn't required on
  the target Mac.

## Known limits

- Overlapping simultaneous speakers on a single mixed mono feed can't be fully
  separated by any single-stream STT.
