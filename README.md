# Advisor

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
     • trigger classifier (persistent Haiku session, delta-fed)
     • parallel research lanes (web search + vault, read-only)
     • on-demand query lane
```

- **App** (`App/`): Swift/SwiftUI. Captures the microphone and system audio
  (ScreenCaptureKit), transcribes on-device, dedups speaker echo, shows a
  chronological feed of sentences with research cards inlined, and writes each
  session to markdown. STT engines: whisper.cpp (vendored) and Apple
  SpeechAnalyzer (macOS 26+).
- **Sidecar** (`sidecar/`): Node 22 + TypeScript + Claude Agent SDK. Watches the
  transcript, decides what is worth researching (questions, topics, claims —
  including questions about the user's own notes), researches in parallel
  persistent sessions, and streams answer cards back. Uses the local Claude
  Code login (subscription), not an API key.

## Setup

```sh
# whisper.cpp (vendored, built once)
git clone --depth 1 https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build vendor/whisper.cpp/build -j
sh vendor/whisper.cpp/models/download-ggml-model.sh large-v3-turbo
sh App/setup.sh            # symlinks whisper headers into the CWhisper shim

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
release build plus the whisper dylibs (in `Frameworks/`, rpath-fixed), the Node
runtime, and the built sidecar. Node is **not** required on the target Mac.

**On the build machine** (Apple Silicon), you need:

- the dev setup above completed once — in particular whisper.cpp built at
  `vendor/whisper.cpp/build` (the script aborts if it's missing);
- the Xcode toolchain (`swift`, `codesign`, `install_name_tool`);
- an arm64 `node` on `PATH` — its binary is copied into the bundle.

**Build:**

```sh
cd App && sh package.sh        # → App/dist/Advisor.app
```

The script runs a release `swift build`, builds the sidecar (`npm install` +
`tsc`), assembles the `.app`, strips the dev build-tree rpaths, and ad-hoc
signs it. Re-run it any time; it rebuilds `dist/Advisor.app` from scratch.

**Install on another Mac** (macOS 26+, Apple Silicon):

1. Copy `Advisor.app` across (e.g. to `/Applications`).
2. Clear the quarantine flag, since the app is ad-hoc-signed, not notarised:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Advisor.app   # or right-click ▸ Open
   ```

3. Ensure a logged-in Claude Code CLI is present — the sidecar's agents use it.
4. Launch. First run prompts for Microphone and Screen & System Audio
   Recording permissions.

The whisper model is **not** bundled — the shipped app defaults to Apple
SpeechAnalyzer, which needs no model. To use whisper instead, drop a
`ggml-*.bin` at
`~/Library/Application Support/Advisor/models/ggml-large-v3-turbo.bin` or point
`ADVISOR_WHISPER_MODEL` at one, then pick whisper in Preferences.

## Use

Click **Listen**. Words appear live in grey as they're spoken, replaced by
finalised sentences; cards appear inline when the assistant decides something
is worth answering, checking, or explaining — or when you ask via the query
box. Transcript text is selectable; **right-click** a selection (or the whole
sentence) to run **Answer / Context / Fact check** on it directly — the same
actions the assistant triggers automatically, gated by the same preference
toggles, with the resulting card anchored under that line. Once a card has
finished, a follow-up box appears on it — ask a question about the card and the
answer is appended in place, so a card becomes a short thread. The menu also lets
you copy the text or add words to the STT dictionary (whisper engine only —
Apple has no vocabulary hook). The **mic** button mutes the local microphone
while the session keeps running — system audio is still captured and
transcribed; tap again to unmute. `Float` keeps the window on top. Sessions are
saved as markdown under
`~/Library/Application Support/Advisor/sessions/` (`Sessions` button).

## Preferences

⌘, opens settings: the research agents' editable persona/style prompt (with
Restore default — the operational core stays fixed), extra instructions, parallel
agent count, connector action permissions, trigger sensitivity
(conservative/balanced/eager) and per-kind toggles, the provider + model for
each component (classifier, research, manual query), STT engine (Apple/whisper),
system-audio capture, and STT locale. Stored in
`~/Library/Application Support/Advisor/config.json`; agent settings apply at the
next session start. The toolbar keeps only in-session controls: Listen, pause,
mic mute, mic device, Auto cards, Float. Below it sits an optional **session
prompt** box (who's present, the topic, what to focus on): fill it before Listen
or edit it live during the session to steer the agents — each edit applies to
the next card. It clears when the session stops.

Each component can run on **Claude** (Agent SDK) or **Codex** (`@openai/codex-sdk`)
independently. Codex uses your Codex CLI login (`~/.codex/auth.json`) — no API
key — and runs read-only (web search + file reads, no writes). Its sandbox is
coarser than Claude's per-path policy (a read-only shell command can read
sensitive dotfiles; Codex MCP servers come from `~/.codex/config.toml` and
aren't gated by the connector-actions toggle) — see DESIGN.md. To use Codex,
have the `codex` CLI logged in.

Advisor itself knows nothing about your notes: the research agents load your
own Claude configuration (`~/.claude/CLAUDE.md`), which is where vault
locations and personal context belong.

## Safety

Research agents are sandboxed by tool policy: web search, the user's MCP
connectors (Slack, Jira, … — read/search only unless "Allow connector actions"
is enabled), and read-only access to non-sensitive files in the home directory.
No shell, no writes; credential paths (~/.ssh, ~/.aws, ~/.claude, ~/.codex,
keychains, …) are denied (case-insensitively). File search (Grep/Glob) must be
scoped to a specific subdirectory — an unscoped home-wide search is refused so a
recursive pattern can't reach a denied path.

## Documents

- [REQUIREMENTS.md](REQUIREMENTS.md) — what it must do, decisions made
- [DESIGN.md](DESIGN.md) — architecture, protocol, milestones, tuning history

## Known limits

Overlapping simultaneous speakers on a mixed mono feed cannot be fully
transcribed by any single-stream STT. The trigger classifier and research
agents consume Claude Max subscription allowance; the cost ticker shows
API-equivalent value, not money billed.
