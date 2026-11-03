# Using Advisor

The everyday guide: recording, the Sessions browser, preferences, providers,
safety and logs. For the short version, see
[Getting started](../README.md#getting-started).

## Recording

Advisor opens on the **Sessions** browser (see [below](#sessions-browser)). To
open the recording window, click the red record button at the top of the
sidebar, choose **File → New Recording**, or press ⌘N. Only one recording
window exists, so a second ⌘N brings it forward.

Click **Listen** in the recording window. Words show in grey as they are
spoken, and finalised sentences replace them. A card appears in the
conversation when the assistant finds something to answer, check or explain,
or when you **Ask**. If microphone permission or speech startup fails, fix the
problem that the window reports and press **Resume**. The transcript so far
stays.

The recording window and the Sessions detail show the same feed: the
conversation as plain text, with the time of each paragraph in the margin, and
cards and notes in place on a faint fill. A past session reads as it did live.

In the recording window, the feed follows new content: new lines, notes and
cards, and the text of a card as its answer arrives. Scroll up to stop it, for
example to read a card. Scroll back to the bottom to follow again.

### Toolbar

The left side holds the record cluster (waveform, timer, mic mute, stop) and
the audio source. The right side holds **Ask**, **Note**, the target folder
(when you record into one), **Name**, **Context**, **Tags**, **Auto cards**,
**Hide transcript**, **Summarise**, **Float** and **Export**. When idle, the
cluster is a single **Listen** button. Hover an icon for its tooltip, also when
another app is in front. In a narrow window, **Hide transcript**,
**Summarise**, **Float** and **Export** move into a **More** (…) menu, as
**Hide Transcript**, **Summarise**, **Float on Top** and **Export…**. The other
controls then lose their labels.

- **Stop** pauses capture but keeps the session live, and **Resume** continues
  it with full context. The session ends when you close the recording window.
  If cards are still researching, the close asks you to **Wait** for them or to
  **Stop and Close**. A close, and a quit with ⌘Q, adds the last speech to the
  note before the save.
- **Ask** (⌘K) opens a box for a question about the conversation, or about
  anything else. The answer comes as a card. **Return** sends it, and **⌥↵**
  starts a new line. You can ask again while an answer is in progress, and the
  answers come at the same time. When too many are in progress (normally
  three), or a question cannot start, it shows as a failed card with your
  question and the reason, so that you can ask it again later.
- **Note** (⇧⌘N) opens a box for your own context, such as a name that the
  audio misheard, or what "the migration" means. It shows as a green **Note**
  card at this point in the conversation, and the assistant reads it as part of
  the conversation, so it can inform or start research.
- Ask and Note also work before **Listen**: they open the transcript, and an
  answer that is still in progress continues. A note reaches the assistant at
  once, so an Ask before Listen can use it. Both boxes keep your text if you
  click away, and a dot on the button shows a waiting draft.
- **Auto cards** turns the automatic answer, context and fact-check cards off
  and on. Off applies at once: research that waits does not start, but cards
  that already research finish. When you turn it on again, it starts from what
  is said next, not from the time while it was off.
- The **mic** button mutes your microphone. The session continues, and system
  audio is still transcribed. Click again to unmute.
- **Name** (before or during a session) is a short label that titles the
  session in the browser.
- **Context** (before or during a session) holds the **session prompt**: who is
  present, the topic, and what to focus on. Edit it live to steer the agents;
  each edit applies to the next card. **Load** fills it from a saved context,
  and **Save…** stores the current text as one. Name, context and tags clear
  when the recording window closes, not on Stop.
- **Tags** (before or during a session) applies tags from your library. Create
  tags in Preferences.
- **Hide transcript** (eye icon) shows only the cards and notes. Click again to
  show the transcript. While the transcript is hidden or the window floats,
  **More** shows in the accent colour.
- **Summarise** adds a Summary card of the conversation so far, or updates the
  existing one.
- **Float** keeps the window on top.
- **Export** (share icon) copies the session note to a location that you
  choose.

### Keyboard shortcuts

- **⌘N**: New Recording, or bring the recording window forward.
- **Space**: Listen, Stop or Resume, in the recording window (not while you
  type in a field).
- **Esc**: Stop.
- **⌘K**: Ask.
- **⇧⌘N**: Add Note.
- **⌘,**: Preferences.

### The transcript

You can select transcript text. **Right-click** a selection, or a paragraph
with no selection, to:

- run **Answer**, **Context** or **Fact check** on it. These are the actions
  that the assistant starts automatically, behind the same preference toggles.
  The card goes under the last line of the paragraph.
- correct a misheard word: **Correct "…"…** changes this occurrence, and
  **Replace all "…"…** changes every occurrence in the session. A paragraph
  shows several transcript lines together, and a selection across two lines
  cannot be corrected: the menu says so. Select within one line.
- **Add note here…**: the **Note** box opens and shows the line that the note
  goes under (✕ there sends it to the end). The note shows as a green **Note**
  card at that line. To delete a note, hover it and click ✕.
- copy the text.

### Cards

A finished card has a follow-up box. Ask a question about the card, and the
answer is added to the card, so a card becomes a short thread. A question that
is not sent, for example because the sidecar is not running, stays in the box.
Summary cards take no follow-ups. While a card researches, it shows what the agent does, such
as *Searching the web for “…”* or *Thinking…*, and the answer shows as it is
written. The ✕ beside *Researching* (**Skip this card**) stops it. The card
stays in the window, marked cancelled, but the saved note leaves it out.

A card keeps the answer that it already has. While a follow-up or a
re-summarise runs, the saved note keeps the previous answer, and a cancel puts
it back. A failed re-summarise keeps the old summary with a line that says so;
click Summarise again to retry.

Hover a card for its controls: **Copy** (the title and the body), collapse or
expand (fact-checks start collapsed), and delete (✕). A delete of a card that
still researches stops its research.

### Where sessions are saved

Each session is a markdown note in
`~/Library/Application Support/Advisor/sessions/`, with the cards in place in
the conversation, as the window shows them. A summary is the exception: it
leads the note in its own `# Summary` section. You can choose another folder in
Preferences, which offers to move the existing notes.

## Sessions browser

The **Sessions** browser is the main window, and it opens at launch. It shows
your past sessions, with a list on the left and the selected session on the
right.

### The list

The sidebar groups the sessions that are not in a folder by date (Today,
Yesterday, Earlier this week, This month and Earlier). A folder lists its
sessions without groups. **Search** also matches tags, and `#tag` filters by
tag only. The filter button at the end of the field switches between all
sessions and this week, and between newest and oldest first. It shows in the
accent colour while it shows this week only. Each row shows the session's
title (its name, else the context that you typed before Listen, else the
date), a gist, the duration, the card count and a coloured dot for each tag
(hover for the names).

### Folders

Folders show as collapsible sections above the sessions. To add one, hover the
**Folders** label and click `+`.

- **Filing.** Drag a session onto a folder, or right-click it and choose
  **Move to Folder** (a folder, **No Folder** for a session in a folder, or
  **New Folder…**).
- **Rename and delete.** Right-click a folder header. A delete moves the
  folder's sessions back out and keeps them. Folders are real folders in the
  storage folder, so Finder shows them too.
- **The live session.** You cannot move the session of the recording window
  until that window closes. You also cannot rename or delete its folder, also
  while it is stopped.
- **Record into a folder.** Hover a folder header and click its red **record
  button**. The recording window opens, and the note is saved in that folder
  from the start. The folder is fixed when you press Listen; to move the
  session later, use **Move to Folder**.
- **Folder context.** The speech-bubble button sets a context (who is there,
  what it is about) that each recording started in the folder takes as its
  starting session context. You can edit it in each session. **Load** fills it
  from a saved context. The bubble is filled when the folder has a context.
- **Folder tags.** The tag button sets default tags from your library. Each new
  recording started from the folder takes them, and you can change them before
  or during the session. Existing sessions, and sessions that you move into the
  folder, do not change.

### Session detail

The detail shows the title and details of the session, the questions that you
asked, and the transcript in the same feed as the recording window. It has the
recording window's controls, and each edit is saved into the note:

- **Hover a card** to copy, collapse, expand or delete it (✕). Hover a note to
  delete it (✕). A delete of the summary or of the last follow-up removes its
  heading too.
- **Follow up on a finished card**: the answer is added to the card.
- **Right-click the transcript** for **Answer**, **Context** or **Fact check**
  (the card is saved when it finishes; a failed or skipped card is not), **Add
  note here…**, and **Correct "…"…** or **Replace all "…"…**.
- **Note** in the toolbar (⇧⌘N) adds a note at the end of the transcript.

If the note changed on disk after the detail showed it, an edit that no longer
fits is not made. The detail says so and reloads, and you can try again. Two
edits are different. A follow-up that cannot be saved stays on screen, so that
you can copy it. A note for a line that changed stays in the **Note** box, and
the detail says that it will go at the end of the transcript. Send it again, or
right-click to choose another line. An edit to a note that moved to another
folder (in Finder, for example) is saved where the note is now. Ask, Summarise,
a follow-up and the right-click research actions also read the note where it
is now. If the note cannot be read, for example because it was deleted in
Finder, nothing is sent, and the detail says so.

You can read and collapse the session that is still recording, and change its
name and tags. Other edits wait until it is fully saved.

The right end of the toolbar holds **Ask**, **Note**, **Hide Transcript**,
**Summarise**, **Tags** and the `…` menu:

- **Rename…**: a short label for the list. Leave it blank to use the context.
- **Export…**: save a copy of the markdown.
- **Share…**: the macOS share sheet (Mail, AirDrop, Messages and others).
- **Reveal in Finder**: show the session's markdown file.
- **Delete…**: permanently remove the note from disk, after a confirmation. You
  cannot delete the live session.

The right-click menu of each list row has the same actions.

### Asking a past session

**Ask** in the toolbar (⌘K) takes a question about the selected session. The
answer shows at the bottom, and when it is finished, it is added to the note
under a `# Follow-ups` heading. While an answer or a Summarise runs, the ✕ on
its panel stops it: nothing is saved, and a stopped question goes back into the
Ask box.

## Preferences

⌘, opens the settings:

- **Agent:** the backend (one provider and model for the classifier, the
  research lanes and the query lane), the card **effort**, authentication, the
  number of parallel agents, and connector actions.
- **Triggers:** sensitivity (conservative, balanced or eager), and a toggle for
  each card kind.
- **Transcription:** system-audio capture and the speech-recognition locale.
- **Contexts** and **Tags:** your saved contexts, and the tag library (add,
  rename, recolour, delete). A tag rename updates every session that uses it.
- **General:** appearance (system, light or dark), the session folder, and
  transcript text in the log (off by default; see [Logs](#logs)).

Agent settings apply at the next session start, and appearance at once.
**Parallel agents** applies at once while the recording window is open, and
otherwise at the next launch of Advisor. **Capture system audio** applies at the
next Listen or Resume.

**Effort** is the main control for card speed. **Default** uses the effort in
your own Claude Code settings (`effortLevel` in `~/.claude/settings.json`),
which can be high for coding. **Low** is the fastest and **Max** the slowest.
It applies to every card, follow-up, Ask and Summarise, but not to the trigger
classifier. A level that the model cannot use is lowered to one that it can
(Extra high becomes High on Sonnet; Haiku ignores effort). Claude only.

## Providers and authentication

Every agent lane uses one backend: **Claude** (the Agent SDK) by default, or
**Codex** (`@openai/codex-sdk`). Choose it in Preferences. Codex uses your
Codex CLI login, so log in to the `codex` CLI first.

Preferences has no Codex model of its own: Codex uses the `model` in
`~/.codex/config.toml`. Advisor runs the Codex CLI that it bundles, not the one
on your `PATH`, so the model must be one that the bundled CLI supports. If a
Codex card fails with "requires a newer version of Codex", the model is newer
than the bundled CLI. Choose an older model in `~/.codex/config.toml`, or
update Advisor.

**Authentication** uses your CLI subscription login by default (Claude Code or
Codex). On a Mac with no CLI login, set **Authentication** to *API key* and
paste an Anthropic or OpenAI key, to match the provider. Preferences checks the
key with the provider when you enter it. The key is kept in your macOS
Keychain, not in `config.json`. Use of the key is billed to that key, not to
your subscription. A change of authentication, key or provider applies at the
next recording session.

Advisor itself knows nothing about your notes. On Claude, the research agents
load your own Claude configuration (`~/.claude/CLAUDE.md`), which is where note
locations and personal context belong. Codex agents do not load it, and cannot
read `~/.claude`.

## Safety

On **Claude**, a tool policy limits each research agent call:

- Web search and fetch are allowed.
- Your MCP connectors (Slack, Jira, …) can read and search. Other connector
  tools, and tools that the policy does not recognise, need **Allow connector
  actions**.
- Files under your home folder can be read, but not changed. Credential paths
  (`~/.ssh`, `~/.aws`, `~/.claude`, `~/.codex`, keychains, …) are denied, also
  through symlinks and in any letter case. A file search must name a folder
  that holds no credential path.
- No shell, and no other Claude Code tool (skills, scheduling, sub-agents, …).

The policy applies before the permission rules of Claude Code, so allow rules
in your Claude settings cannot widen it.

On **Codex**, the Codex CLI runs under a macOS Seatbelt profile, built from the
same list of credential paths. Codex, and each process that it starts, cannot
read those paths, and can write only to Codex's own state and temporary
folders. Even there, it cannot change Codex's configuration, hooks or
instructions. This is coarser than the Claude policy: Codex can read its own
`~/.codex` login, and it cannot allow connector reads and refuse actions. So
with **Allow connector actions** off it gets no connectors (no MCP servers or
plugins from `~/.codex/config.toml`, and no ChatGPT apps), and with it on, it
gets all of them.

Codex cards cannot run shell commands. Codex can try one, but the Codex CLI
cannot start its own sandbox inside the profile, so the command fails. So,
unlike a Claude card, a Codex card cannot read your local notes. Only a
connector can reach them, and Codex gets connectors only with **Allow
connector actions** on. See [DESIGN.md](../DESIGN.md).

## Logs

The app and the sidecar write diagnostics to
`~/Library/Logs/Advisor/advisor.log`. Console.app shows the file under **Log
Reports**. To follow it live, run `tail -f ~/Library/Logs/Advisor/advisor.log`.
The file rotates at about 5 MB and keeps one previous copy (`advisor.log.1`).

By default the log holds no transcript text: each line shows as its length.
The agents' output (card text, and the classifier's triggers, which restate
what was said) is still logged, for the diagnosis of cards. To debug
transcription, turn on **Include transcript text in the log** under
Preferences → General. It applies at once, also during a recording. The log is
then session data, as the transcripts are. In both cases, the log stays on your
Mac.

If the main thread of the app stops for 5 seconds or more, the app can log the
stall and save a stack sample of itself next to the log, as
`hang-<n>-<time>.txt`. A stop of about 7 seconds or more is always caught. The
folder keeps the newest five. When you close the recording window, the log
also records which control had keyboard focus in each window. Attach the sample
and the log to a hang report.

## About

**Advisor → About Advisor** shows the version, what Advisor does, the main
components with their licences, and the copyright. Advisor is open source
under the MIT licence.

## Known limits

No single-stream speech recogniser can fully transcribe overlapping speakers
on a mixed mono feed. The trigger classifier and the research agents use your
provider subscription's allowance, or your API key when you set one.
