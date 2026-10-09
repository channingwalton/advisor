# Advisor — agent guide

Personal macOS assistant that listens to live conversations, transcribes them
on-device, and proactively surfaces answer/context/fact-check cards using
Claude agents. It uses whatever connectors are present to search for content,
including the web. Single user (Channing), runs locally, no server.

Read [docs/guide.md](docs/guide.md) for app behaviour,
[docs/development.md](docs/development.md) for packaging and releases,
[DESIGN.md](DESIGN.md) for architecture and decision history,
[REQUIREMENTS.md](REQUIREMENTS.md) for scope. DESIGN.md's dated sections
record why things are the way they are — check them before re-litigating a
decision.

## Layout

- `App/` — Swift/SwiftUI macOS app (SwiftPM, macOS 26, Swift language mode v5).
  Audio capture (mic + ScreenCaptureKit system audio), on-device STT via
  Apple SpeechAnalyzer, echo dedup, chronological feed UI (selectable
  transcript lines with a right-click action menu — AI actions, corrections,
  and editorial NOTE cards), session markdown writer,
  a Sessions browser (master/detail: date-grouped list + detail with cards,
  questions and transcript; folders with per-folder context and tags, session
  tags, search, ask-and-append, summarise), saved contexts, first-run terms,
  quit/close teardown (`QuitSequence`, `SessionClose`), preferences.
- `sidecar/` — Node 22 + TypeScript, two agent backends: Claude Agent SDK and
  Codex SDK (`src/providers.ts`, kept in step with the app's Preferences).
  Trigger classifier (persistent delta-fed session on the shared model) driving
  automatic cards (`autoPipeline.ts`); pooled research and query lanes plus
  short-lived reply, document and summary lanes (`lanes.ts`); tool sandbox.
  NDJSON over stdio to the app (protocol in `src/protocol.ts`, both directions).

## Build & test

```sh
cd App && swift build                  # app
cd App && swift test                   # app tests
cd sidecar && npm run build            # tsc (npm install --include=dev first)
cd sidecar && npm test                 # tsc + node --test (incl. sandbox.sdk against the real CLI)
mise run commit-check                  # clean build + test both sides, warnings as errors (as CI)
sh sidecar/test/replay.sh              # replay fragments through the pipeline (needs jq + built dist)
cd App && sh package.sh                # → dist/Advisor.app (self-contained; sign-local.sh: Developer ID › "Advisor Dev" › ad-hoc)
cd App && sh install.sh                # clean build + install to ~/Applications
cd App && sh dmg.sh                    # signed + notarised DMG (runs sign.sh; one notary round)
mise run release                       # DMG + sync www version line and DMG link + commit + tag vVERSION
```

Versioning: the repo-root `VERSION` file is the single source of truth —
`package.sh` stamps it into the bundle (build number = commit count) and
`dmg.sh` names the DMG from it. Bump and commit `VERSION` before
`mise run release` — it refuses an uncommitted bump.

Resource paths resolve via `AppResources` (bundle when packaged, `repoRoot`
in a dev checkout) — keep new runtime-resource lookups going through it.

CI (`.github/workflows/ci.yml`) builds and tests both sides on push to `main`
and on PRs (App on `macos-26`, sidecar on `ubuntu-latest`). Always build both
sides locally before committing too. The commit check and CI build Swift with
`-warnings-as-errors`; a plain `swift build` doesn't, and `devtool check` hides
compiler output when it passes — so a warning only shows by failing the check.

## Verifying UI changes

Native macOS GUI — not browser-drivable, and most visual/runtime behaviour
(recording, STT, window lifecycle, cards) isn't unit-testable. "`swift build` +
tests green" is **not** done for these: observe it in the running app or report
it unverified — never frame test-green as done for a visual/runtime ticket (this
drove the #21 rework and #12 churn).

- Screenshot the dev build: `cd App && swift build`, launch the `.build` binary,
  capture a window with `screencapture -l <windowid>` (ids via CGWindowList).
  Full-screen `screencapture` / `osascript` clicks need Accessibility /
  Screen-Recording grants and usually fail.
- **Verify the binary the user runs.** A packaged `dist/Advisor.app` can predate
  your edits — confirm it's rebuilt (mtime / `package.sh`) before trusting a
  "still happening" or a colour/layout mismatch (#21 red-vs-blue, #12 stale).
- A screenshot Read into the session is re-injected on every later turn (one
  127KB PNG became ~50 identical attachments in #12). Capture cropped/small, and
  prefer delegating a visual check to a subagent (it returns a text verdict; the
  image dies with it) over Reading many screenshots into the main loop.

## Conventions & constraints

- Work in main, don't branch unless told to
- Always keep docs up to date
- British spelling in UI strings, prompts, and docs.
- The app must stay generic: no personal paths (vault, etc.) in code — the
  user's own Claude config (`~/.claude/CLAUDE.md`) carries personal context,
  loaded via `settingSources: ["user"]`.
- Claude agents are sandboxed in `sidecar/src/agent.ts` by one policy,
  `toolDecision`: an allowlist of web + ToolSearch + MCP read/search +
  non-sensitive `$HOME` reads by absolute or `~` path (symlinks resolved before the
  denylist check; Glob patterns must stay relative); MCP tools fail closed —
  anything not recognised as a read/search is gated by the `allowMcpActions`
  preference. It is enforced by the `sandboxGate` PreToolUse hook, because the
  SDK approves in-cwd reads and the user's settings allow rules before
  `canUseTool` is ever asked; `canUseTool` repeats the check. Verify sandbox
  changes against the real CLI (`sandbox.sdk.test.ts`), not just the predicate.
  Do not weaken this silently. Codex (`sidecar/src/codex.ts`) has no per-call hook, so it is
  sandboxed at the process boundary instead: `sidecar/src/codexSandbox.ts`
  builds a Seatbelt profile from the same `deniedPaths()` list and the CLI runs
  under `sandbox-exec` via `codexPathOverride`. Its own `sandboxMode:
  "read-only"` is kept but not relied on — it bounds writes only, and MCP tools
  bypass it (openai/codex#4152). Residual: Codex can read its own `~/.codex`
  credentials, which the profile must leave readable for login. Connectors
  follow `allowMcpActions`, all or none (`codexClientOptions`): `--config`
  overrides merge into the user's config, so servers are disabled by name, and
  `--ignore-user-config` would drop the user's model too. Verify against the
  real CLI (`codex.sdk.test.ts`). See DESIGN.md.
- User preferences: `~/Library/Application Support/Advisor/config.json`
  (mirrored by `App/.../Preferences.swift` and `sidecar/src/config.ts` —
  change both together; keys commented "App-side only" in Preferences.swift,
  e.g. `sttLocale`, `sessionDir`, are deliberately absent from the sidecar config).
- Auth defaults to the user's Claude Code / Codex CLI login (subscription);
  never make an API key *required*. An opt-in API-key fallback exists
  (Preferences "Authentication" picker): keys live in the macOS Keychain
  (`Keychain.swift`), injected as `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` at
  sidecar spawn (`SidecarManager.apiKeyEnv`), never in `config.json`.
- Sessions/transcripts are user data, by default in
  `~/Library/Application Support/Advisor/sessions` (the `sessionDir` preference
  can move them) — read freely when debugging, never commit their contents.
- Known limit (don't fight it): overlapping simultaneous speakers on a mono
  feed can't be fully transcribed.
- Disable the blue focus ring on buttons (`.focusEffectDisabled()`).
