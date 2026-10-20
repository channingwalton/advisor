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
- **Locale-aware** — pick the speech recognition locale in Preferences from
  the supported list, or leave it on **System default** to follow your Mac's
  locale.

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
- **Auto cards switch** — turn automatic cards off from the toolbar while
  transcription carries on. Off takes effect at once (nothing waiting starts;
  cards already researching finish); back on, it picks up from what's said
  next.
- **Two-tier speed** — a fast classifier decides *whether* to act in under a
  second, leaving the research agent the rest of the budget to answer
  (aspiration: a useful card within a few seconds).

## Ask anything

- **Ask** — a toolbar button (⌘K) opens a box to ask a question at any time,
  before Listen too, about the current conversation or anything else; the live
  transcript is used as context.
- **Right-click transcript actions** — select any transcript text and run
  **Answer / Context / Fact check** on it directly — the same actions the
  assistant triggers automatically — with the card anchored under that line.
  The menu also fixes a misheard word (**Correct** that instance or **Replace
  all** in the session) and copies the selected text.
- **Editorial notes** — the toolbar's **Note** (⇧⌘N) adds your own note as a
  distinct NOTE card at this point in the conversation — before Listen too —
  and right-click a transcript line ▸ *Add note here…* anchors one at that
  line. The
  assistant treats it as authoritative context — it can itself trigger
  research — and it round-trips through the saved markdown. Deletable.
- **Card follow-ups** — once a card is done, ask a follow-up on it and the
  reply is appended in place, turning a card into a short thread.
- **Card controls** — collapse, expand, copy, or dismiss any card; dismissing
  one that's still researching cancels its work.
- **Summarise on demand** — one tap distils the whole conversation into a
  Summary card — live or on a saved session — and it's kept with the note.

## Recording window

- **Floating mode** — keep the window always-on-top so it sits beside your call
  without stealing focus.
- **Resumable stop** — **Stop** pauses capture but keeps the session live;
  **Resume** picks it back up with full context. The session is finalised when
  the window closes.
- **Session context prompt** — set who's present, the topic, and what to focus
  on before you start, or edit it live to steer the assistant; each change
  applies to the next card.
- **Rename live** — a Name chip in the toolbar renames the session while
  recording; the Sessions sidebar updates immediately.
- **Cards-only view** — hide the transcript with one tap to watch just the
  cards stream in.
- **Export** — copy the current session note to a location you choose.

## Sessions browser

The app opens on a master/detail browser of your past sessions:

- **Grouped & searchable list** — sessions grouped by day (Today / Yesterday /
  Earlier this week / …), with search and a filter menu (all / this week,
  newest / oldest first). Each row shows a title, a gist, duration, card count
  and a dot per tag.
- **Full session detail** — title and meta, the questions you asked, and the
  transcript in the same feed as the live window, with the surfaced cards
  inline and the same controls: copy, collapse/expand, delete and follow up on
  cards, and right-click the transcript to research a passage (Answer / Context
  / Fact check), add a note or correct a word — all saved to the note.
- **Ask-and-append** — ask a question about a past session; the answer streams
  in and is appended to that session's note under a **Follow-ups** heading, so
  the saved transcript grows with the questions you ask of it. Stop an Ask or
  Summarise while it runs and nothing is saved; a stopped question returns to
  the Ask box.
- **Rename, export, share, reveal & delete** — give a session a short name for
  an easier-to-scan list, export a copy of its markdown, **Share…** it through
  the macOS share sheet, reveal its markdown file in Finder, or delete it
  (behind a confirmation). Available from the toolbar's `…` menu and from each
  list row's right-click menu, which also has *Move to Folder*.

## Organisation

- **Folders** — organise sessions into folders in the Sessions sidebar, with
  children indented under their folder. Each folder header has a record button
  to start a recording straight into that folder. Re-file existing sessions
  later by dragging them onto a folder or via *Move to Folder*.
- **Folder defaults** — a folder can carry a **folder context** that seeds the
  session prompt of recordings started there (stored as a hidden `.context.md`
  that travels with renames and storage-dir moves; **Load** fills it from a
  saved context) and **default tags** those recordings inherit. Both stay
  editable per session.
- **Tags** — a user-managed library of coloured tags. Apply them from the live
  toolbar or the browser; they show as coloured dots on session rows and are
  searchable (type `#tag` to filter). Renaming a tag updates it everywhere.
- **Saved contexts** — pre-canned context prompts for common setups: **Load**
  one into a session's or folder's context instead of retyping it, or
  **Save…** the recording window's current context as a new one.
- **Markdown sessions** — every session is saved as a portable markdown file
  with cards embedded inline, in a folder you choose.

## Sources

Advisor researches across whatever you've connected:

- **Web search** — built in.
- **Your notes & connectors** — your notes and work tools such as Jira,
  Confluence and Slack, through the connectors your AI provider already has
  (configured outside Advisor); read-only by default on Claude.
- **Local files** — read-only access to non-sensitive files in your home
  directory.

## Privacy & safety

- **Local-first** — STT is on-device; listening is always explicitly
  user-initiated.
- **Sandboxed research (Claude)** — a per-call tool policy allows web search,
  read/search-only connectors, and read-only home-directory access. No shell,
  no writes. Credential paths (`~/.ssh`, `~/.aws`, `~/.claude`, keychains, …)
  are denied — case-insensitively, with symlinks resolved so a link can't slip
  past the denylist. Enforced ahead of Claude Code's own permission rules, so
  allow rules in your Claude settings can't widen it.
- **Sandboxed research (Codex)** — coarser, because the Codex SDK has no
  per-call hook: the Codex CLI runs under a macOS Seatbelt profile built from
  the same credential-path denylist, so it and every process it starts (shell
  commands, MCP servers) can't read those paths or write anywhere but Codex's
  own state and temp folders. Read-only shell *is* permitted, and Codex can
  still read its own `~/.codex` login. Codex can't let connector reads through
  while refusing actions, so with "Allow connector actions" off it gets no
  connectors at all (the MCP servers and plugins in your `~/.codex/config.toml`,
  and ChatGPT apps); with it on, it gets all of them.
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
  sensitivity and per-kind toggles, agent backend, model and card effort, saved
  contexts, the tag library, system-audio capture, STT locale, and the session
  storage folder.
- **Effort** — how much Claude thinks before answering a card: Low is fastest,
  Max slowest, and **Default** follows your own Claude Code setting. Applies to
  every card, follow-up, Ask and Summarise, not the trigger classifier; a level
  the model can't use is lowered to one it can. Claude only.
- **Appearance** — system, light, or dark.

## Packaging

- **Self-contained app** — `package.sh` builds a self-contained, ad-hoc-signed
  `Advisor.app` bundling the Node runtime and sidecar. Node isn't required on
  the target Mac.

## Known limits

- Overlapping simultaneous speakers on a single mixed mono feed can't be fully
  separated by any single-stream STT.
