# Advisor — agent guide

A personal macOS assistant. It listens to live conversations, transcribes them
on-device, and shows answer, context and fact-check cards that Claude or Codex
agents research through the web and the user's connectors. Single user
(Channing), runs locally, no server.

Read the document that matches the task:

- [docs/guide.md](docs/guide.md): app behaviour, as the user sees it.
- [DESIGN.md](DESIGN.md): architecture and decision history. Its dated
  sections give the reason for each decision: read the matching section before
  you change a decision.
- [REQUIREMENTS.md](REQUIREMENTS.md): scope, and the requirement tags that the
  tests carry.
- [docs/development.md](docs/development.md): packaging, signing and releases.

## Layout

- `App/`: the Swift/SwiftUI macOS app (SwiftPM, macOS 26, Swift language mode
  v5). Audio capture, on-device STT (Apple SpeechAnalyzer), echo dedup, the
  feed, the session markdown writer, the Sessions browser and preferences.
  Close and quit teardown are in `SessionClose` and `QuitSequence`.
- `sidecar/`: Node 26 and TypeScript, with two agent backends, the Claude Agent
  SDK and the Codex SDK (`src/providers.ts`, kept in step with the app's
  Preferences). The trigger classifier, a persistent session fed only new
  lines, drives automatic cards (`autoPipeline.ts`). `lanes.ts` holds the
  pooled research and query lanes and the one-shot reply, document and summary
  lanes. NDJSON over stdio to the app (`src/protocol.ts`, both directions).
- `protocol/examples.json`: one example frame for each message type in each
  direction. Both test suites load it (`sidecar/src/protocol.test.ts`,
  `App/Tests/AdvisorTests/ProtocolContractTests.swift`), so a field renamed on
  one side fails a test. Change it with the protocol.

## Build & test

```sh
cd App && sh xcode.sh swift build      # app, under the Xcode .xcode-version pins
cd App && sh xcode.sh swift test       # app tests
cd sidecar && npm run build            # tsc (npm install --include=dev first)
cd sidecar && npm test                 # tsc + node --test (incl. sandbox.sdk against the real CLI)
sh sidecar/test/replay.sh              # replay fragments through the pipeline (needs jq + built dist)
cd App && sh package.sh                # → dist/Advisor.app (self-contained; sign-local.sh: Developer ID › "Advisor Dev" › ad-hoc)
cd App && sh install.sh                # clean build + install to ~/Applications
cd App && sh dmg.sh                    # signed + notarised DMG (runs sign.sh; one notary round)
```

`mise.toml` defines two more tasks. Run a task with mise (`mise run <task>`),
or run the commands that the task lists:

- `commit-check`: a clean build and test of both sides, with Swift warnings as
  errors, as in CI.
- `release`: the DMG, the `vVERSION` tag, a push and a GitHub release.

The repo-root `VERSION` file is the single source of truth for the version:
`package.sh` stamps it into the bundle (build number = commit count), and
`dmg.sh` names the DMG from it. Commit the `VERSION` bump before you run the
`release` task, which refuses an uncommitted bump.

Resolve runtime resources through `AppResources` (the bundle when packaged,
`repoRoot` in a dev checkout).

CI (`.github/workflows/ci.yml`) builds and tests both sides on each push to
`main` and on each PR: the app on `macos-26` under the pinned Xcode, the
sidecar on `ubuntu-latest`. Build both sides locally before you commit. The
`commit-check` task and CI compile Swift with `-warnings-as-errors`, but a
plain `swift build` does not. So a warning that a plain build accepts fails
the commit check and CI.

## Verifying UI changes

Advisor is a native macOS GUI: a browser cannot drive it, and unit tests cannot
reach most visual and runtime behaviour (recording, STT, window lifecycle,
cards). For such a change, green builds and tests are not done. Observe the
change in the running app, or report it as unverified. Issues #21 and #12 had
rework because of this.

- Screenshot the dev build: run `cd App && sh xcode.sh swift build`, launch the
  `.build` binary, and capture its window with `screencapture -l <windowid>`
  (ids from CGWindowList). A full-screen `screencapture` and `osascript` clicks
  need Accessibility and Screen Recording grants, and usually fail.
- **Verify the binary that the user runs.** A packaged `dist/Advisor.app` can be
  older than your edits. Confirm that it is rebuilt (its mtime, or a
  `package.sh` run) before you trust a report that a fault "still happens" or
  that a colour or layout is wrong.
- A screenshot that you Read comes back on every later turn: in #12, one 127 KB
  PNG became about 50 attachments. Capture small, cropped images, and give a
  visual check to a subagent, which returns a text verdict.

## Conventions & constraints

- Commit to `main`. Make a branch only when told to.
- Pin exact versions. Node is pinned in `.tool-versions`, which Node version
  managers, CI (`node-version-file`) and `package.sh` (which bundles that Node)
  all read.
  Xcode is pinned in `.xcode-version`. Every swift step (commit check,
  `package.sh`, `install.sh`, CI) runs through `App/xcode.sh`, which selects
  that Xcode by version and refuses to run without it. npm dependencies are
  exact in `sidecar/package.json`, and `sidecar/.npmrc` sets `save-exact`.
- Update the docs in the same change as the behaviour that they describe.
- Use British spelling in UI strings, prompts and docs.
- Keep the app generic: code holds no personal paths (a vault, for example).
  Personal context comes from the user's own Claude configuration
  (`~/.claude/CLAUDE.md`), which the agents load through
  `settingSources: ["user"]`.
- **The agent sandbox is a security boundary.** Before you change it, read its
  entries in DESIGN.md (*Agent sandboxing*, *Codex runs under a Seatbelt
  profile*, *Codex connectors follow the actions toggle*). Change it only on
  purpose, record the change there, and verify it against the real CLI
  (`sandbox.sdk.test.ts`, `codex.sdk.test.ts`), not only the predicate.
  - Claude: one policy, `toolDecision` (`sidecar/src/agent.ts`). The
    `sandboxGate` PreToolUse hook enforces it, because the SDK approves reads
    in the working directory, and the user's allow rules, before it asks
    `canUseTool`. MCP tools fail closed.
  - Codex has no per-call hook, so its boundary is a Seatbelt profile
    (`sidecar/src/codexSandbox.ts`) built from the same `deniedPaths()` list.
    Keep its own `sandboxMode: "read-only"`: it cannot apply inside the
    profile, so each Codex shell command fails closed (#118).
- User preferences are in `~/Library/Application Support/Advisor/config.json`,
  mirrored by `App/.../Preferences.swift` and `sidecar/src/config.ts`. Change
  both together. Keys commented "App-side only" in Preferences.swift (such as
  `sttLocale` and `sessionDir`) are absent from the sidecar config on purpose.
- Authentication defaults to the user's Claude Code or Codex CLI login
  (subscription), and an API key stays optional. API keys live in the macOS
  Keychain (`Keychain.swift`), not in `config.json`: see *Optional API-key
  auth* in DESIGN.md.
- Sessions and transcripts are user data, by default in
  `~/Library/Application Support/Advisor/sessions` (the `sessionDir`
  preference can move them). Read them freely when you debug, and keep their
  contents out of commits.
- Known limit: overlapping speakers on a mono feed cannot be fully
  transcribed. Leave it.
- Disable the blue focus ring on buttons (`.focusEffectDisabled()`).
