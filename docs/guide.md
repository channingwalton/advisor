# Using Advisor

The everyday guide: recording, the Sessions browser, preferences, providers,
safety and logs. For the short version see
[Getting started](../README.md#getting-started); for every feature in one list,
[FEATURES.md](../FEATURES.md).

## Recording

Advisor opens on the **Sessions** browser (see [below](#sessions-browser)).
Click the red **New Recording** button at the top of its sidebar, beside the
window controls (or press ⌘N), to open a recording window; only one recording
window exists at a time, so doing it again just brings it forward.

In the recording window, click **Listen**. Words appear live in grey as they're
spoken, replaced by finalised sentences; cards appear inline when the assistant
decides something is worth answering, checking, or explaining — or when you ask
via the query box. If microphone permission or speech startup fails, fix the
reported problem and press **Resume**; failed speech recovery also leaves Resume
available and keeps the existing transcript.

The recording window and the Sessions detail share one feed: the conversation
as plain text with each paragraph's time in the margin, and cards and notes
inline on a faint fill, so a past session reads just as it did live.

### Toolbar

The toolbar keeps only in-session controls: the record cluster (waveform,
timer, mic mute, stop) and audio source on the left; on the right the target
folder (when recording into one), **Name**, **Context**, **Tags**, **Auto
cards**, **Hide transcript**, **Summarise**, **Float** and **Export**. Idle
collapses the cluster to a single **Listen** pill.

- **Stop** is resumable — it pauses capture but keeps the session live, and the
  cluster offers **Resume** to pick it back up with full context. The session is
  finalised when the recording window closes. If cards are still researching,
  closing asks whether to **Wait** for them or **Stop and Close**. Closing — and
  quitting with ⌘Q — lets the last speech reach the note before it's saved.
- **Auto cards** turns the automatic answer/context/fact-check cards on and
  off. Off takes effect at once — nothing waiting to be researched starts —
  though cards already researching finish. Turned back on, it picks up from
  what is said next, not the stretch while it was off.
- The **mic** button in the record cluster mutes the local microphone while the
  session keeps running — system audio is still captured and transcribed; tap
  again to unmute.
- **Name** (before or during a session) is an optional short label that titles
  the session in the browser.
- **Context** (before or during a session) holds the **session prompt** (who's
  present, the topic, what to focus on). Fill it before Listen or edit it live to
  steer the agents; each edit applies to the next card. **Load** fills it from a
  saved context; **Save…** stores the current text as one. Name, context and
  tags clear when the recording window closes, not on Stop.
- **Tags** (before or during a session) applies tags from your library (pick
  from the list; create them in Preferences).
- **Hide transcript** (eye icon) shows only the cards; click again to bring the
  transcript back.
- **Summarise** adds a Summary card recapping the conversation so far, or
  updates the existing one.
- **Float** keeps the window on top.
- **Export** (share icon) copies the current session note to a location you
  choose.

### Keyboard shortcuts

- **⌘N** — New Recording (or bring the recording window forward).
- **Space** — Listen, Stop or Resume (not while typing in a field).
- **Esc** — Stop.
- **⌘↵** — Ask, from the query box (Return works too).
- **⌘,** — Preferences.

### The transcript

Transcript text is selectable. **Right-click** a selection (or the whole
sentence) to:

- run **Answer / Context / Fact check** on it directly — the same actions the
  assistant triggers automatically, gated by the same preference toggles, with
  the resulting card anchored under that line;
- fix a mis-transcribed word: **Correct "…"** (just that instance) or **Replace
  all "…"** (every occurrence in the session); type the correction and it's
  saved to the transcript in place;
- **Add note here…** when the audio missed context — your note lands as a green
  **Note** card at that point and the assistant reads it as part of the
  conversation (so it can inform, or trigger, research); delete it with the ✕
  that shows when you hover it;
- copy the text.

### Cards

Once a card has finished, a follow-up box appears on it — ask a question about
the card and the answer is appended in place, so a card becomes a short thread.
(Summary cards are a one-shot recap and take no follow-ups.) While a card is
still researching it shows what the agent is doing, such as *Searching the web
for “…”* or *Thinking…*, and the answer appears as it is written. The ✕ beside
*Researching* (**Skip this card**) stops it; the card stays, marked cancelled.
A card never loses an answer it has already given: while a follow-up or a
re-summarise runs, the saved note keeps the previous answer; cancelling one puts
it back, and a failed re-summarise keeps the old summary with a line saying it
couldn't be updated (Summarise again to retry).
Hover a card for its controls: **Copy** (puts the title, body and any sources
on the clipboard), collapse/expand (a collapsed card keeps its chevron showing;
fact-checks start collapsed) and delete (✕); deleting a card that's still
researching cancels its lane.

### Where sessions are saved

Sessions are saved as markdown under
`~/Library/Application Support/Advisor/sessions/` by default — Preferences lets
you choose another folder (and offers to move existing transcripts across) — with
cards embedded inline in the conversation just as the window shows them.

## Sessions browser

The **Sessions** browser is the app's main window: it opens at launch. It's a
master/detail window over past sessions.

### The list

The left sidebar lists sessions grouped by day (Today / Yesterday / Earlier this
week / …) with a **Search** field (which also matches tags; type `#tag` to filter
by tag specifically). The filter button at its end switches between all sessions
and this week, and between newest and oldest first (it turns the accent colour
while showing this week only). Each row shows the session's title (its name if
you gave it one, else the context you typed before Listen, else the date), a
gist, duration and card count, and a coloured dot per tag (hover for the names).

### Folders

The sidebar's **Folders** label (hover it for a `+` to add one) lists
collapsible folder sections above the date-grouped sessions.

- **Filing.** Drag a session's row onto a folder, or use its **right-click**
  menu → **Move to Folder** (existing folders, **No Folder** to take it back
  out, or **New Folder…**).
- **Renaming and deleting.** Right-click a folder header. Deleting a folder
  moves its sessions back out and keeps them. Folders are real sub-directories
  under the storage folder, so they show in Finder too.
- **The live session.** The session owned by the Recording window cannot be
  re-filed until that window closes, and its containing folder cannot be renamed
  or deleted either, including while stopped. Closing drains the last speech
  results before saving and releasing the note; a reopened Recording window waits
  for that save.
- **Recording into a folder.** Hover a folder header to show its buttons; its
  red **record button** opens the recording window filed into that folder, so its
  note is saved there straight away (the recording window shows the target
  folder). The folder is fixed once you press Listen; re-file afterwards with
  **Move to Folder**.
- **Folder context.** The speech-bubble button beside a folder's record button
  sets context (who's there, what it's about) that every recording started in
  that folder inherits as its starting session context — editable per session.
  **Load** fills it from one of your saved contexts (Preferences ▸ Contexts).
  The bubble is filled when a folder has a context set.
- **Folder tags.** The adjacent **tag button** sets default tags from your
  library; every new recording started from that folder inherits them, and you
  can adjust them before or during the session. Existing sessions and sessions
  moved into the folder are unchanged.

### Session detail

Selecting a session shows it on the right: title and meta, the questions you
asked, and the transcript in the same feed as the recording window, with the
cards Advisor surfaced inline and each paragraph's time in the margin. It has
the recording window's controls too, and edits are saved into the note:

- **Hover a card or note** to copy it, collapse/expand it (fact-checks start
  collapsed) or delete it (✕) — straight away, as in the recording window;
  deleting the summary or the last follow-up removes its heading too.
- **Follow up on a finished card**: the answer is appended to the card.
- **Right-click the transcript** for **Answer / Context / Fact check** (the card
  streams in under that paragraph and is saved when it finishes; a failed or
  skipped one isn't), **Add note here…** (a green Note card at that line), and
  **Correct "…"** / **Replace all "…"**.

The session still being recorded can be read and collapsed here, but not edited
until it has fully saved.

The toolbar's right-hand end holds **Hide Transcript**, **Summarise**, **Tags**
(applies or removes tags, picking from your library) and the `…` menu:

- **Rename** — a short label for an easier-to-scan list; leave it blank to fall
  back to the context.
- **Export…** — save a copy of the markdown elsewhere.
- **Share…** — the macOS share sheet (Mail, AirDrop, Messages, etc.).
- **Reveal in Finder** — opens the session's markdown file.
- **Delete** — behind a confirmation; it permanently removes the note from disk.
  The live session can't be deleted.

The same actions are also on each list row's **right-click** menu.

### Asking a past session

Ask a question about the selected session in the field at the bottom: the
answer streams in and, once finished, is appended to that session's note under a
`# Follow-ups` heading, so the saved transcript grows with the questions you ask
of it. (The session currently being recorded is read-only here until it has
fully saved.) While an answer or a Summarise is running, the ✕ on its panel stops
it: nothing is saved, and a stopped question goes back in the field to edit or
send again.

## Preferences

⌘, opens settings: parallel agent count, connector action permissions, trigger
sensitivity (conservative/balanced/eager) and per-kind toggles, the agent
backend (one provider + model shared by the classifier, research, and
manual-query lanes), the card **effort** (how much Claude thinks before
answering a card — see below), saved contexts, the **tag** library (add / rename / recolour
/ delete, each with a preset colour; renaming updates the tag on every session
already using it), appearance (system/light/dark), system-audio capture, the
speech-recognition locale, and the session storage folder (choose where
transcripts are saved; changing it offers to move existing ones across).

Most settings are stored in `~/Library/Application Support/Advisor/config.json`;
agent settings apply at the next session start, appearance straight away.
**Parallel agents** and **Capture system audio** live in the app's own defaults
instead: the agent count applies straight away, system audio from the next
Listen or Resume.

**Effort** is the main speed dial for cards. "Default" uses the effort level
in your own Claude Code settings (`effortLevel` in `~/.claude/settings.json`),
which may be set high for coding. Low is fastest; Max is slowest. It applies to
every card, follow-up, Ask and Summarise, but not to the trigger classifier. A
level the chosen model can't use is lowered to one it can (Extra high becomes
High on Sonnet; Haiku ignores effort). Claude only. Each run's level appears
in the log's `run start` lines, so card timings can be compared by level.

## Providers and authentication

Every agent lane (classifier, research, query) shares one backend — **Claude**
(Agent SDK) by default, or **Codex** (`@openai/codex-sdk`) — picked in
Preferences. Codex uses your Codex CLI login (`~/.codex/auth.json`), so to use
it, have the `codex` CLI logged in.

**Authentication** defaults to the provider's subscription login (Claude Code /
Codex CLI). On a machine with no CLI login, switch **Authentication** to *API
key* in Preferences and paste an Anthropic or OpenAI key (whichever matches the
selected provider). The key is stored in your macOS Keychain — never in
`config.json` — and injected into the sidecar's environment
(`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`). Authentication mode, key replacements
and provider changes apply when the next recording session starts: Advisor
reloads the selected key and replaces the sidecar only when its authentication
changes. Returning to subscription removes both provider API-key overrides.
Preferences validates the key directly against the provider's models endpoint
when you enter it, showing inline status and an alert on rejection, so an
invalid key surfaces immediately rather than as a mid-session research error.
API-key usage is billed to that key, not your subscription.

Advisor itself knows nothing about your notes: the research agents load your
own Claude configuration (`~/.claude/CLAUDE.md`), which is where note
locations and personal context belong.

## Safety

On **Claude**, research agents are sandboxed by a per-call tool policy: web
search, the user's MCP connectors (Slack, Jira, … — read/search only unless
"Allow connector actions" is enabled), and read-only access to non-sensitive
files in the home directory. No shell, no writes; credential paths (~/.ssh,
~/.aws, ~/.claude, ~/.codex, keychains, …) are denied (case-insensitively, with
both requested paths and denied roots resolved through symlinks, so symlinked
credential directories stay denied at their targets too). Connector tools fail
closed — anything not recognised as a read/search is treated as an action and
gated. File search (Grep/Glob) must be scoped to a specific subdirectory — an
unscoped home-wide search, or a subtree containing a resolved credential path,
is refused so a recursive pattern can't reach a denied path. File tools take
absolute or `~/…` paths, and search patterns must stay inside the folder being searched.
Any other Claude Code tool (skills, scheduling, sub-agents, …) is refused. The
policy is checked before Claude Code's own permission rules, so allow rules in
your Claude settings can't widen it.

On **Codex**, which has no per-call hook, the sandbox is at the process
boundary: the Codex CLI runs under a macOS Seatbelt profile built from the same
denylist, so it and every process it starts (shell commands, MCP servers) can't
read those paths or write anywhere but Codex's own state and temp folders. It's
coarser than the Claude policy: read-only shell commands are allowed, and Codex
can read its own `~/.codex` login. Codex can't let connector reads through while
refusing actions, so with the connector-actions toggle off it gets no connectors
at all (the MCP servers and plugins in `~/.codex/config.toml`, and ChatGPT
apps); with it on, it gets all of them. See [DESIGN.md](../DESIGN.md).

## Logs

Diagnostics from both the app and the sidecar are written to
`~/Library/Logs/Advisor/advisor.log` — the standard macOS user logs folder, so
it also appears in Console.app under **Log Reports**. Tail it live with
`tail -f ~/Library/Logs/Advisor/advisor.log`. The file rotates at ~5 MB, keeping
one previous copy (`advisor.log.1`). Diagnostic lines include recognised
utterance text, so treat it as session data — like the transcripts themselves,
it stays on your machine.

## Known limits

Overlapping simultaneous speakers on a mixed mono feed cannot be fully
transcribed by any single-stream speech recogniser. The trigger classifier and
research agents consume your provider subscription's allowance.
