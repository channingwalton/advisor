# Advisor

[![CI](https://github.com/channingwalton/advisor/actions/workflows/ci.yml/badge.svg)](https://github.com/channingwalton/advisor/actions/workflows/ci.yml)

A personal macOS assistant that listens to conversations in realtime — meetings,
calls, videos, in-person — transcribes them locally, and proactively surfaces
answers, background context, and fact-checks as the conversation flows. Ask it
questions about (or beyond) the conversation at any time. The Obsidian vault,
the web, and connected tools are its sources; nothing is recorded, only
transcripts are kept.

## How it works

```
mic ──┐
      ├─ audio capture ─ STT (on-device) ─ echo dedup ─┐
sys ──┘                                                ├─ Swift app (UI, sessions)
                                                       │
                NDJSON over stdio                      │
                                                       ▼
   TS sidecar — Claude Agent SDK:
     • trigger classifier (persistent session, delta-fed)
     • parallel research lanes (web search + vault, read-only)
     • on-demand query lane
```

- **App** (`App/`): Swift/SwiftUI. Captures the microphone and system audio
  (ScreenCaptureKit), transcribes on-device, dedups speaker echo, shows a
  chronological feed of sentences with research cards inlined, and writes each
  session to markdown. STT is Apple SpeechAnalyzer (macOS 26+), on-device.
- **Sidecar** (`sidecar/`): Node 22 + TypeScript + Claude Agent SDK. Watches the
  transcript, decides what is worth researching (questions, topics, claims —
  including questions about the user's own notes), researches in parallel
  persistent sessions, and streams answer cards back. Uses your local CLI
  login (Claude Code subscription, or Codex CLI) by default; an API key is an
  optional fallback for machines with no CLI login (see below).

## Setup

```sh
# sidecar
cd sidecar && npm install --include=dev && npm run build

# app
cd ../App && swift build
.build/debug/Advisor
```

Requires: macOS 26+ (Apple Silicon), Xcode toolchain, Node 22+, a logged-in
Claude Code CLI. First run prompts for Microphone and Screen & System Audio
Recording permissions (attributed to the launching terminal).

## Build a release

`App/package.sh` assembles a self-contained, ad-hoc-signed `Advisor.app` —
release build plus the Node runtime and the built sidecar. Node is **not**
required on the target Mac.

**On the build machine** (Apple Silicon), you need:

- the Xcode toolchain (`swift`, `codesign`);
- an arm64 `node` on `PATH` — its binary is copied into the bundle.

**Build:**

```sh
cd App && sh package.sh        # → App/dist/Advisor.app
```

The script runs a release `swift build`, builds the sidecar (`npm install` +
`tsc`), assembles the `.app`, and ad-hoc signs it. Re-run it any time; it
rebuilds `dist/Advisor.app` from scratch.

To clean-build **and** install over your own copy in one step:

```sh
cd App && sh install.sh        # → ~/Applications/Advisor.app
```

`install.sh` wipes prior build artefacts, runs `package.sh`, quits a running
Advisor, then replaces `~/Applications/Advisor.app` and clears its quarantine
flag.

**Install on another Mac** (macOS 26+, Apple Silicon):

1. Copy `Advisor.app` across (e.g. to `/Applications`).
2. Clear the quarantine flag, since the app is ad-hoc-signed, not notarised:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Advisor.app   # or right-click ▸ Open
   ```

3. Ensure a logged-in Claude Code CLI is present — the sidecar's agents use it.
4. Launch. First run prompts for Microphone and Screen & System Audio
   Recording permissions.

## Use

Advisor opens on the **Sessions** browser — your past sessions (see below). Click
**Record** (top right) to open a recording window; only one recording window exists
at a time, so clicking Record again just brings it forward.

In the recording window, click **Listen**. Words appear live in grey as they're
spoken, replaced by
finalised sentences; cards appear inline when the assistant decides something
is worth answering, checking, or explaining — or when you ask via the query
box. The **Context** button (before or during a session) holds an optional
**name** — a short label that titles the session in the browser — and a context
prompt that steers the assistant. The **Tags** chip (before or during a session)
applies tags from your library (pick from the list; create them in Preferences);
they show as coloured pills in the browser. Transcript text is selectable; **right-click** a selection (or the whole
sentence) to run **Answer / Context / Fact check** on it directly — the same
actions the assistant triggers automatically, gated by the same preference
toggles, with the resulting card anchored under that line. Once a card has
finished, a follow-up box appears on it — ask a question about the card and the
answer is appended in place, so a card becomes a short thread. The menu also lets
you copy the text. Each card can be collapsed/expanded or dismissed (fact-checks
start collapsed); dismissing a card that's still researching cancels its lane.
The **mic** button in the record cluster mutes the local microphone
while the session keeps running — system audio is still captured and
transcribed; tap again to unmute. `Float` keeps the window on top. Sessions are
saved as markdown under
`~/Library/Application Support/Advisor/sessions/` by default — Preferences lets
you choose another folder (and offers to move existing transcripts across) — with
cards embedded inline in the conversation just as the window shows them. The
**Export** button (share icon) copies the current session note to a location you
choose.

The **Sessions** browser is the app's main window (it opens at launch; the
recording window's **History** button, clock icon, brings it forward) — a master/
detail window over past sessions. The left sidebar lists sessions grouped by day
(Today / Yesterday / Earlier this week / …) with search (which also matches tags;
type `#tag` to filter by tag specifically), an All / This week
filter and a recent/oldest sort toggle; each row shows the session's title (its name if you gave it one, else the
context you typed before Listen, else the date), a gist, duration and card count,
and any tags as coloured pills.
Organise sessions into **folders**: the sidebar's **FOLDERS** bar (with a `+` to
add one) lists collapsible folder sections above the date-grouped sessions. File
a session by dragging its row onto a folder, or via its **right-click** menu →
**Move to Folder** (existing folders, **No Folder** to take it back out, or
**New Folder…**). Right-click a folder header to rename or delete it — deleting a
folder moves its sessions back out and keeps them. Folders are real
sub-directories under the storage folder, so they show in Finder too. The session
currently being recorded can't be filed until it has finished.
Selecting one shows it on the right: title and meta, the questions you asked, and
the transcript rendered like the live window (with the cards Advisor surfaced
inline, as in the live view). The detail header's **Tags** chip applies or
removes tags (picking from your library). Give a session a name with the
`…` menu → **Rename**
(top right of the detail) — a short label for an easier-to-scan list; leave it
blank to fall back to the context. The same menu has **Export…** (save a copy of
the markdown elsewhere), **Share…** (the macOS share sheet — Mail, AirDrop,
Messages, etc.), **Reveal in Finder** (opens
the session's markdown file) and **Delete** (behind a confirmation — it
permanently removes the note from disk); the live session can't be deleted. The
same actions are also on each list row's **right-click** menu.
Ask a question about the selected session in the box at the bottom: the answer
streams in and, once finished, is appended to that session's note under a
`# Follow-ups` heading, so the saved transcript grows with
the questions you ask of it. (The session currently being recorded is read-only
here until it has fully saved.)

## Preferences

⌘, opens settings: parallel
agent count, connector action permissions, trigger sensitivity
(conservative/balanced/eager) and per-kind toggles, the agent backend (one
provider + model shared by the classifier, research, and manual-query lanes),
saved contexts, the **tag** library (add / rename / recolour / delete, each with a
preset colour; renaming updates the tag on every session already using it),
appearance (system/light/dark), system-audio capture, STT locale, and the
session storage folder (choose where transcripts are saved; changing it offers to
move existing ones across). Stored in
`~/Library/Application Support/Advisor/config.json`; agent settings apply at the
next session start. The toolbar keeps only in-session controls: the record
cluster (waveform, timer, stop, mic mute), audio source, **Context**, Auto
cards, Float, Export, History, Sessions (idle collapses the cluster to a single
Listen pill). **Stop** is resumable — it pauses capture but keeps the session
live, and the cluster offers **Resume** to pick it back up with full context; the
session is finalised when the recording window closes. The
**Context** chip opens a **session prompt** popover (who's present, the topic,
what to focus on): fill it before Listen or edit it live during the session to
steer the agents — each edit applies to the next card. It clears when the
session stops.

Every agent lane (classifier, research, query) shares one backend — **Claude**
(Agent SDK) by default, or **Codex** (`@openai/codex-sdk`) — picked in
Preferences. Codex uses your Codex CLI login (`~/.codex/auth.json`) — no API
key — and runs read-only (web search + file reads, no writes). Its sandbox is
coarser than Claude's per-path policy (a read-only shell command can read
sensitive dotfiles; Codex MCP servers come from `~/.codex/config.toml` and
aren't gated by the connector-actions toggle) — see DESIGN.md. To use Codex,
have the `codex` CLI logged in.

**Authentication** defaults to the provider's subscription login (Claude Code /
Codex CLI). On a machine with no CLI login, switch **Authentication** to *API
key* in Preferences and paste an Anthropic or OpenAI key (whichever matches the
selected provider). The key is stored in your macOS Keychain — never in
`config.json` — and injected into the sidecar's environment at launch
(`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`). Preferences validates the key directly
against the provider's models endpoint when you enter it, showing inline status
and an alert on rejection, so an invalid key surfaces immediately rather than as
a mid-session research error. Note that API-key usage is billed to
that key, not your subscription. Changing it applies on the next Listen.

Advisor itself knows nothing about your notes: the research agents load your
own Claude configuration (`~/.claude/CLAUDE.md`), which is where vault
locations and personal context belong.

## Safety

On **Claude**, research agents are sandboxed by a per-call tool policy: web
search, the user's MCP connectors (Slack, Jira, … — read/search only unless
"Allow connector actions" is enabled), and read-only access to non-sensitive
files in the home directory. No shell, no writes; credential paths (~/.ssh,
~/.aws, ~/.claude, ~/.codex, keychains, …) are denied (case-insensitively, with
symlinks resolved so a link can't point past the denylist). Connector tools fail
closed — anything not recognised as a read/search is treated as an action and
gated. File search (Grep/Glob) must be scoped to a specific subdirectory — an
unscoped home-wide search is refused so a recursive pattern can't reach a denied
path. On **Codex** the sandbox is coarser (see above) — no per-call policy.

## Logs

Diagnostics from both the app and the sidecar are written to
`~/Library/Logs/Advisor/advisor.log` — the standard macOS user logs folder, so
it also appears in Console.app under **Log Reports**. Tail it live with
`tail -f ~/Library/Logs/Advisor/advisor.log`. The file rotates at ~5 MB, keeping
one previous copy (`advisor.log.1`). Diagnostic lines include recognised
utterance text, so treat it as session data — like the transcripts themselves,
it stays on your machine.

## Documents

- [FEATURES.md](FEATURES.md) — the feature list, in plain language
- [REQUIREMENTS.md](REQUIREMENTS.md) — what it must do, decisions made
- [DESIGN.md](DESIGN.md) — architecture, protocol, milestones, tuning history

## Known limits

Overlapping simultaneous speakers on a mixed mono feed cannot be fully
transcribed by any single-stream STT. The trigger classifier and research
agents consume Claude Max subscription allowance.
