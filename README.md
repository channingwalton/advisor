# Advisor

[![CI](https://github.com/channingwalton/advisor/actions/workflows/ci.yml/badge.svg)](https://github.com/channingwalton/advisor/actions/workflows/ci.yml)

A personal macOS assistant that listens to conversations in realtime — meetings,
calls, videos, in-person — transcribes them locally, and proactively surfaces
answers, background context, and fact-checks as the conversation flows. Ask it
questions about (or beyond) the conversation at any time, or summarise the whole
conversation on demand (live or from a saved session). Your notes, the web,
and connected tools are its sources; nothing is recorded, only
transcripts are kept.

## Getting started

1. **Install.** Build the DMG from source (see
   [docs/development.md](docs/development.md)), open it and drag Advisor to
   Applications.
2. **Grant permissions.** On first launch Advisor asks for **Microphone** and
   **Screen & System Audio Recording** — both are needed to hear the
   conversation.
3. **Choose your AI backend.** Open Preferences (⌘,) and pick a provider under
   the agent backend setting:
   - **Claude** — uses your logged-in Claude Code CLI (a Claude subscription).
   - **Codex** — uses your logged-in Codex CLI (an OpenAI/ChatGPT subscription).

   Pick whichever you already have signed in on this Mac; that's all the
   configuration most people need. (No CLI login? Switch **Authentication** to
   *API key* in Preferences and paste an Anthropic or OpenAI key instead —
   billed to that key.)
4. **Record.** Click **New Recording**, then **Listen**. The conversation transcribes
   live and Advisor surfaces answer, context and fact-check cards as it goes.

That's it. Everything stays on your Mac — nothing is uploaded except the
research queries your chosen AI provider runs.

## Build from source

```sh
cd sidecar && npm install --include=dev && npm run build
cd ../App && swift build && .build/debug/Advisor
```

Requires macOS 26+ on Apple Silicon, the Xcode toolchain and Node 26.11.1
(pinned in `.tool-versions`; `mise install` fetches it).
Packaging, signing and releases are in
[docs/development.md](docs/development.md).

## Documentation

- [docs/guide.md](docs/guide.md) — using Advisor: recording, sessions,
  preferences, providers, safety, logs
- [docs/development.md](docs/development.md) — architecture, building,
  packaging, releasing
- [FEATURES.md](FEATURES.md) — the feature list, in plain language
- [REQUIREMENTS.md](REQUIREMENTS.md) — what it must do, decisions made
- [DESIGN.md](DESIGN.md) — architecture, protocol, milestones, tuning history

## Licence

MIT — see [LICENSE](LICENSE).
