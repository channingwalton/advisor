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

## Use

Click **Listen**. Words appear live in grey as they're spoken, replaced by
finalised sentences; cards appear inline when the assistant decides something
is worth answering, checking, or explaining — or when you ask via the query
box. The `STT` picker switches between Apple speech (default, macOS 26) and
whisper.cpp; clicking words adds them to the STT dictionary (whisper engine
only — Apple has no vocabulary hook). `Agents` sets research parallelism.
`Pin` floats the window. Sessions are saved as markdown under
`~/Library/Application Support/Advisor/sessions/` (`Sessions` button).

## Safety

Research agents are sandboxed by tool policy: they can search the web and read
the vault, nothing else — no shell, no writes, no files outside the vault.

## Documents

- [REQUIREMENTS.md](REQUIREMENTS.md) — what it must do, decisions made
- [DESIGN.md](DESIGN.md) — architecture, protocol, milestones, tuning history

## Known limits

Overlapping simultaneous speakers on a mixed mono feed cannot be fully
transcribed by any single-stream STT. The trigger classifier and research
agents consume Claude Max subscription allowance; the cost ticker shows
API-equivalent value, not money billed.
