# Advisor

[![CI](https://github.com/channingwalton/advisor/actions/workflows/ci.yml/badge.svg)](https://github.com/channingwalton/advisor/actions/workflows/ci.yml)

A personal macOS assistant that listens to conversations in realtime — meetings,
calls, videos, in-person — transcribes them locally, and proactively surfaces
answers, background context, and fact-checks as the conversation flows. Ask it
questions about (or beyond) the conversation at any time, or summarise the whole
conversation on demand (live or from a saved session). Your notes, the web,
and connected tools are its sources; nothing is recorded, only
transcripts are kept.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="www/img/recording-dark.png">
  <img alt="The recording window: a live transcript with answer and fact-check cards placed where they were raised." src="www/img/recording-light.png">
</picture>

## Getting started

1. **Install.** Download the DMG from
   [advisor.monoidal.co.uk](https://advisor.monoidal.co.uk), open it and drag
   Advisor to Applications.
2. **Accept the terms.** First launch shows the [Terms of Use](TERMS.md)
   (also at [advisor.monoidal.co.uk/terms.html](https://advisor.monoidal.co.uk/terms.html))
   — recording and AI features stay off until accepted.
3. **Grant permissions.** On first launch Advisor asks for **Microphone** and
   **Screen & System Audio Recording** — both are needed to hear the
   conversation.
4. **Choose your AI backend.** Open Preferences (⌘,) and pick a provider under
   the agent backend setting:
   - **Claude** — uses your logged-in Claude Code CLI (a Claude subscription).
   - **Codex** — uses your logged-in Codex CLI (an OpenAI/ChatGPT subscription).

   Pick whichever you already have signed in on this Mac; that's all the
   configuration most people need. (No CLI login? Switch **Authentication** to
   *API key* in Preferences and paste an Anthropic or OpenAI key instead —
   billed to that key.)
5. **Record.** Click **Record**, then **Listen**. The conversation transcribes
   live and Advisor surfaces answer, context and fact-check cards as it goes.

That's it. Everything stays on your Mac — nothing is uploaded except the
research queries your chosen AI provider runs.

## Build from source

```sh
cd sidecar && npm install --include=dev && npm run build
cd ../App && swift build && .build/debug/Advisor
```

Requires macOS 26+ on Apple Silicon, the Xcode toolchain and Node 26.10.0
(pinned in `.tool-versions`; `mise install` fetches it).
Packaging, signing and releases are in
[docs/development.md](docs/development.md).

## Documentation

- [docs/guide.md](docs/guide.md) — using Advisor: recording, sessions,
  preferences, providers, safety, logs
- [docs/development.md](docs/development.md) — architecture, building,
  packaging, releasing, the website
- [FEATURES.md](FEATURES.md) — the feature list, in plain language
- [REQUIREMENTS.md](REQUIREMENTS.md) — what it must do, decisions made
- [DESIGN.md](DESIGN.md) — architecture, protocol, milestones, tuning history

## Licence

MIT — see [LICENSE](LICENSE).
