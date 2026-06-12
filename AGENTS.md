# Advisor — agent guide

Personal macOS assistant that listens to live conversations, transcribes them
on-device, and proactively surfaces answer/context/fact-check cards using
Claude agents. It uses whatever connectors are present to search for content,
including the web. Single user (Channing), runs locally, no server.

Read [README.md](README.md) for setup/use, [DESIGN.md](DESIGN.md) for
architecture and decision history, [REQUIREMENTS.md](REQUIREMENTS.md) for
scope. DESIGN.md's dated sections record why things are the way they are —
check them before re-litigating a decision.

## Layout

- `App/` — Swift/SwiftUI macOS app (SwiftPM, macOS 26, Swift language mode v5).
  Audio capture (mic + ScreenCaptureKit system audio), two STT engines
  (Apple SpeechAnalyzer default; whisper.cpp via `Sources/CWhisper` shim),
  echo dedup, chronological feed UI (selectable transcript lines with a
  right-click action menu), session markdown writer, preferences.
- `sidecar/` — Node 22 + TypeScript + Claude Agent SDK. Trigger classifier
  (persistent Haiku session, delta-fed), parallel research lanes, query lane,
  `canUseTool` sandbox. NDJSON over stdio to the app (protocol in
  `src/protocol.ts`, both directions).
- `vendor/whisper.cpp` — gitignored; cloned/built per README.

## Build & test

```sh
cd App && swift build                  # app
.build/debug/Advisor --smoke ../vendor/whisper.cpp/samples/jfk.wav
cd sidecar && npm run build            # tsc (npm install --include=dev first)
sh test/replay.sh                      # replay fragments through the pipeline
cd App && sh package.sh                # → dist/Advisor.app (self-contained, ad-hoc signed)
```

Resource paths resolve via `AppResources` (bundle when packaged, `repoRoot`
in a dev checkout) — keep new runtime-resource lookups going through it.

There is no CI. Always build both sides before committing; run the smoke test
after touching whisper/audio code.

## Conventions & constraints

- Work in main, don't branch unless told to
- British spelling in UI strings, prompts, and docs.
- The app must stay generic: no personal paths (vault, etc.) in code — the
  user's own Claude config (`~/.claude/CLAUDE.md`) carries personal context,
  loaded via `settingSources: ["user"]`.
- Agents are sandboxed in `sidecar/src/agent.ts` (`canUseTool`): web + MCP
  read/search + non-sensitive `$HOME` reads only; MCP action tools gated by
  the `allowMcpActions` preference. Do not weaken this silently.
- User preferences: `~/Library/Application Support/Advisor/config.json`
  (mirrored by `App/.../Preferences.swift` and `sidecar/src/config.ts` —
  change both together).
- Auth is the user's Claude Code login (subscription); never introduce an
  API-key requirement.
- Sessions/transcripts are user data in `~/Library/Application Support/Advisor/`
  — read freely when debugging, never commit their contents.
- Known limit (don't fight it): overlapping simultaneous speakers on a mono
  feed can't be fully transcribed; whisper hallucinates on noise (that's why
  Apple STT is the default).
