# Advisor — Design

**Status:** Draft v1 — 2026-06-11
**Input:** [REQUIREMENTS.md](REQUIREMENTS.md)

## Overview

Two processes on one machine:

```
┌─────────────────────────── Swift app ────────────────────────────┐
│                                                                  │
│  AudioCapture ──► Transcription ──► SessionStore (markdown)      │
│   mic: AVAudioEngine   Apple              │                      │
│   sys: ScreenCaptureKit  SpeechAnalyzer   ▼                      │
│                            │         OverlayUI (NSPanel)         │
│                            │              ▲                      │
│                            ▼              │ cards/results        │
│                      SidecarManager ──────┘                      │
└────────────────────────────┼─────────────────────────────────────┘
                   NDJSON over stdio
┌────────────────────────────┼──────────────── TS sidecar ─────────┐
│                            ▼                                     │
│  TriggerDetector ──────────► ResearchAgent (Claude Agent SDK)    │
│                               tools: web search, Vault (RO),     │
│                               Jira/Confluence/Slack MCP, files   │
└──────────────────────────────────────────────────────────────────┘
```

The Swift app owns everything realtime and visual; the sidecar owns everything that thinks. Only text crosses the boundary.

## Components

### Swift app

**AudioCapture.** Two concurrent sources: mic via `AVAudioEngine` tap; system audio via `ScreenCaptureKit` (`SCStream` audio-only, macOS 13+). Each resampled to 16 kHz mono PCM into a ring buffer, tagged `me` (mic) / `them` (system). Echo risk (own voice on both channels during calls): suppress `mic` segments that overlap >80 % in time with near-identical `sys` text; revisit if insufficient.

**Transcription.** Apple SpeechAnalyzer/SpeechTranscriber (macOS 26), on-device. True streaming with built-in endpointing — no hand-rolled VAD — one analyzer per source (mic/system). Emits `Utterance{id, source, text, t0, t1}`. (Originally whisper.cpp; see the dated sections below for the switch and removal.)

**SidecarManager.** Spawns the Node sidecar and supervises it: on a crash it restarts with exponential backoff (1/2/4/8 s, capped 8 s, ≤5 attempts; a crash that follows a >60 s healthy run resets the budget, so only a tight loop exhausts it), then replays the session context the running conversation depends on — `session_start` plus the lane/auto config (not the utterance history; the classifier session is gone, so new utterances resume in a fresh sidecar session). A deliberate `stop()` is distinguished from a crash and cancels any pending restart. Sends to a dead sidecar surface on the status line rather than failing silently; budget exhausted → status asks the user to stop and start listening again. Transport: newline-delimited JSON over stdin/stdout. Chosen over WebSocket: no port management, lifecycle tied to parent, trivially debuggable. The sidecar's stderr is funnelled into the app's log file (see Logging) rather than left to vanish in a packaged app.

**Logging.** All app and sidecar diagnostics go through `FileLog` (`Log.swift`) to `~/Library/Logs/Advisor/advisor.log` — the standard macOS user logs folder, so the file shows up under Console.app → Log Reports and survives a packaged run (where stderr goes nowhere). The app is the *sole* writer: its own lines arrive via `appLog.write`, the sidecar's stderr is captured by `SidecarManager` and funnelled in via `appLog.appendSidecar` (lines reassembled across chunk boundaries, each wall-clock-timestamped). One serial queue → no write contention and a single chronological timeline that interleaves app and `[sidecar +Xs]` lines. Mirrored to stderr too for dev runs. Rotates by size (5 MB), keeping one previous file (`advisor.log.1`).

**OverlayUI.** Non-activating `NSPanel` (`.floating`, `.nonactivatingPanel`) hosting SwiftUI: vertical card feed (newest top), collapsible live transcript drawer, query box, listening indicator. Menu-bar item: start/stop listening, open session history. Panel never takes key focus except when the query box is clicked.

**SessionStore.** One markdown file per session in `~/Library/Application Support/Advisor/sessions/YYYY-MM-DD-HHmmss.md` (second precision, so a same-minute restart can't overwrite the prior transcript): YAML frontmatter (start/end) then the conversation, with finished cards (`done`/`failed`) embedded inline as `>`-quoted "chat" blocks at their place in the stream — the same format the window shows (`SessionMarkdown.inline`). Written incrementally; transcripts only, no audio (decided). Vault is never written. The toolbar **Export** button (share icon → save panel) is just *share the current note*: it flushes and copies the on-disk file to a chosen location, byte-identical (`SessionWriter.export`).

### TS sidecar (Claude Agent SDK)

**TriggerDetector.** Maintains rolling transcript window (~2 min). On each utterance (debounced 1.5 s of silence-or-topic-shift), one classify call (on the shared model — see the 2026-06-13 backend note below) classifies: `question | entity | claim | none` + extracted subject. Dedup: don't re-trigger on a subject already carded in the last 10 min.

**ResearchAgent.** Per trigger, an Agent SDK query with budget caps (max turns ~6, streaming). Tools: web search; read-only filesystem MCP rooted at `~/Documents/Notes` and configured repo dirs; Atlassian + Slack MCPs. System prompt per trigger type (answer / context / fact-check). Fact-check answers must cite or return "couldn't verify" — never guess. Emits card immediately as placeholder, then streams body updates.

**QueryHandler.** F14 on-demand queries: same agent, full current-session transcript as context, results stream to a pinned card.

## IPC contract (NDJSON, one object per line)

Swift → sidecar:

```json
{"type":"session_start","sessionId":"...","ts":...,"context":"..."}
{"type":"session_context","text":"<live edit of the session prompt>"}
{"type":"utterance","id":"u123","source":"them","text":"...","ts":...}
{"type":"query","id":"q7","text":"...","action":"answer|context|factcheck","triggerId":"u123"}
{"type":"config","auto":true,"lanes":3}
{"type":"cancel","cardId":"c9"}
{"type":"card_reply","cardId":"c9","kind":"answer","title":"...","base":"<card's current body>","replyText":"...","transcript":"them: ...\nme: ..."}
{"type":"ask_document","id":"d3","question":"...","document":"<the whole saved transcript note>"}
{"type":"session_end"}
```

Sidecar → Swift:

```json
{"type":"card","id":"c9","trigger":"u123","kind":"answer|context|factcheck|query","title":"...","body":"...","state":"pending|streaming|done|failed|cancelled"}
{"type":"card_update","id":"c9","body":"...","state":"streaming"}
{"type":"document_answer","id":"d3","body":"...","state":"pending|streaming|done|failed"}
{"type":"error","fatal":false,"message":"..."}
```

Versioned with a `hello` exchange at startup.

## Latency budget (best efforts; ≤5 s utterance → useful card is the aspiration)

| Stage | Budget |
|---|---|
| SpeechAnalyzer endpoint + final result | 0.3–1.0 s |
| Trigger classify (shared model) | 0.5 s |
| Placeholder card visible | **≤2 s total** |
| Agent first useful content (streamed) | +2–3 s |

The placeholder-then-stream pattern is what makes the budget achievable; a full agentic search with tool calls will often exceed 3 s on its own.

## Error handling

Sidecar crash → supervisor restarts with exponential backoff (≤5; a healthy run resets the budget), replays the session context (`session_start` + lane/auto config), status line shows the crash and the restart attempt; budget exhausted → status asks the user to stop and start listening again. STT stall → watchdog restarts decode queue. LLM/tool failure → card flips to `failed` with reason; never silent. Anthropic key missing/invalid → blocking banner at session start, not mid-conversation.

## Trade-offs made

| Decision | Alternative | Why |
|---|---|---|
| stdio NDJSON | WebSocket/gRPC | Simplest; lifecycle coupling is a feature here |
| Trigger via Haiku call | Local heuristics/model | Quality >> ~$0.001/utterance; revisit if cost ticker says otherwise |
| Segment-based whisper | True streaming decode | Far simpler; overlap mitigates word splits; M0 validates latency |
| Placeholder + stream cards | Wait for complete answer | Only way to feel responsive within budget |
| Markdown session files | SQLite | Human-readable, greppable, matches "local markdown" decision; revisit if search over history gets slow |

## Milestones

- **M0 — Spike (benchmark): ✅ 2026-06-11.** whisper.cpp + Metal on the M4 Max, 11 s speech sample, warm timings via the Swift wrapper: `small` 130 ms, `large-v3-turbo` 395 ms. Both far inside budget. Default `small` (override with `ADVISOR_WHISPER_MODEL`); `large-v3-turbo` viable if accuracy disappoints.
- **M1: ✅ 2026-06-12 (verified live).** Mic capture → live transcript in a plain window. `App/` Swift package; headless smoke (`--smoke <wav>`) passes; live mic verified. Gotcha found: system default input was BlackHole (virtual, silent) — app now enumerates devices (CoreAudio) and defaults to the first real mic, with a picker. Speech RMS on Studio Display mic ≈ 0.01, VAD floor 0.006 — watch for clipped soft speech.
- **M2: ✅ 2026-06-12.** System audio (ScreenCaptureKit) + me/them tagging + best-effort echo dedup (text overlap vs last 15 s of `them`; `me` delayed 1 s). Apple AEC abandoned: fails (-10875) on multichannel Studio Display output, and mutes the mic when it does initialise. Dedup imperfect but accepted — attribution is cosmetic for Advisor's purpose; duplicates are further caught by trigger-level dedup (M4).
- **M3: ✅ 2026-06-12.** Sidecar + IPC + on-demand query (F14) end-to-end. `sidecar/` (Node 22 + Agent SDK, NDJSON over stdio, web search + Vault read-only, Claude Code auth); Swift `SidecarManager` + cards pane + query box. Verified live. Note: his npm config has `omit=dev` — install with `npm install --include=dev`.
- **M4: ✅ 2026-06-12.** TriggerDetector + automatic cards (F8–F10). Haiku classifier in a *persistent* streaming-input Agent SDK session (~1 s/classify after first; cold spawn per call was ~10 s — the original design's 0.5 s budget was unrealistic via the SDK). Aggressive on questions (incl. musings), conservative on factcheck; named systems/acronyms trigger context. Subject dedup 10 min; research queue sequential. Remaining latency: research agent still cold-spawns per card (~10–30 s incl. tool use) — candidate for the same persistent-session treatment.
- **M5: ✅ 2026-06-13.** Persistent research/query sessions (per-lane transcript-delta cursors; follow-up questions resolve referents from session memory). Cost reporting via per-task `total_cost_usd` deltas → ticker in toolbar. Session markdown files in `~/Library/Application Support/Advisor/sessions/` (debounced rewrite; late cards included). "Float" toggle (floating window, all spaces; named per macOS convention) instead of a full NSPanel overlay — revisit if focus-stealing annoys. "Sessions" button opens the folder in lieu of an in-app history view.

## Post-M5 tuning (2026-06-13, after first real-meeting test)

- Classifier told it reads messy live STT: reassemble fragments, ignore echo near-duplicates; consecutive same-source utterances merged before classification; window 20.
- Brief made explicitly proactive ("trigger every minute or two in substantive conversation").
- Research parallelised: 3 persistent lanes + dedicated query lane, per-lane transcript cursors.
- Replay harness: `sidecar/test/replay.sh` + `fragments.txt` for tuning against real transcripts.

## STT tuning findings (2026-06-12/13)

- `large-v3-turbo` default (proper nouns), beam search size 2, **temperature fallback disabled** — the default 5× re-decode on noisy segments froze the pipeline. Decode now ~300 ms per 5 s segment (≈15× realtime, M4 Max).
- Vocabulary bias via whisper initial_prompt (~224-token cap): manual dictionary (clickable words in UI + Dictionary popover) merged with macOS spelling LocalDictionary. Vault-derived vocab deliberately NOT in the app — user-specific sources belong in the sidecar.
- Echo dedup: pairwise distinctive-word (>3 chars) overlap ≥0.7 on min-length basis; pool-based common-word matching suppressed genuine speech.
- Segment cap 5 s; segments older than 20 s skipped (back-pressure).
- Known limit: overlapping simultaneous speakers on a mixed mono feed are unrecoverable by any single-stream STT — don't engineer against shouty-debate YouTube videos.

## STT engine switch (2026-06-12)

Apple SpeechAnalyzer/SpeechTranscriber (macOS 26) added as the **default** engine; whisper.cpp retained behind a picker for A/B. Apple wins decisively on real-world capture: true streaming with built-in endpointing (complete punctuated sentences, no hand-rolled VAD boundaries), no hallucination-from-noise, and the duplicate/echo problem largely vanishes. Whisper's remaining edge: vocabulary biasing via initial_prompt (Apple path has no equivalent hook in v1) and fully offline model choice. Known minor: Apple's first Listen may download model assets.

Volatile results are enabled: in-progress words render grey/italic at the feed tail and are replaced by the finalised sentence (live-captioning feel). Mic echo delay is 1.5 s on Apple (vs 4 s for whisper) since both streams finalise near-simultaneously.

## Agent sandboxing (2026-06-13)

Sidecar agents run under a `canUseTool` policy instead of `bypassPermissions`: web tools auto-allowed; Read/Grep/Glob restricted to non-sensitive paths under `$HOME` (denylist: .ssh, .aws, .claude, .codex, keychains, …); Bash/Write/Edit/etc. denied and disallowed. Verified: `/etc/passwd` read denied, notes queries unaffected. A hard OS boundary (OrbStack/Docker container, app spawning `docker run -i`) remains a future option — note the OAuth credentials sit inside any such boundary.

Two refinements after review (`sandbox.test.ts` pins them): **Grep/Glob are gated more tightly than Read** because they recurse — validating only the root path lets a recursive pattern (`Glob {path:$HOME, pattern:".ssh/**"}`, `Grep {path:$HOME, pattern:"PRIVATE KEY"}`) reach secrets in a denied descendant. So a search root may not sit *at or above* any denied path; an unscoped `$HOME` search is illegal and the agent must target a specific subtree. **Comparisons are case-folded** — macOS's default filesystem is case-insensitive, so `~/.SSH/id_rsa` reaches the same file as `~/.ssh`; a case-sensitive denylist check would let the variant through. The path-separator guard still keeps distinct siblings (e.g. `.ssh-notes`) allowed.

## Connector tools (2026-06-13)

User-configured MCP connectors (loaded via the user's Claude settings) pass the sandbox: read/search tools always allowed; tools matching an action pattern (send/create/update/delete/…) denied unless `allowMcpActions` is enabled in preferences (default off — a prompt-injected agent must not post to Slack mid-meeting). The research prompt names connected tools as legitimate sources. Toolbar slimmed to in-session controls (Listen, mic, Auto cards, Float); engine/system-audio/agent-count moved to preferences, engine changes applying when listening stops.

## Preferences & de-vaulting (2026-06-13)

Advisor no longer knows about the vault: agents load the user's own Claude config (`settingSources: ["user"]` → `~/.claude/CLAUDE.md`), which carries personal context like note locations. Verified: Patchwork vault query answered with no vault path in Advisor. Preferences (⌘,) write `Application Support/Advisor/config.json`, re-read by the sidecar at each session_start (sessions rebuilt so prompt/model changes apply): trigger sensitivity + per-kind toggles, the shared agent backend (provider + model), STT locale. (Max-triggers-per-pass was dropped as a preference 2026-06-13: "pass" is an invisible internal cadence a user can't reason about, and it duplicated trigger sensitivity as a volume knob; it's now a hardcoded backstop `MAX_TRIGGERS_PER_PASS = 2` in `trigger.ts`.) The research system prompt is entirely fixed in code (`sidecar/src/prompts.ts` — persona plus the protected operational core: two-pass answering, no-narration, citation rules), so prompt edits can't break card latency/format. (The editable persona preference was dropped 2026-06-13: per-session steering via the session prompt below covers the real need, and an editable persona only risked the card contract.) A **session prompt** field steers a single session: filled before Listen (seeded via `session_start`) and editable mid-session (`session_context` messages). Because the persistent research/query lanes fix their system prompt at session start, the session prompt is injected **per task** (`sessionContextPrefix`, prepended to each research/query/reply dispatch and read fresh) rather than into the system prompt — so a live edit lands on the next card without rebuilding lanes. The app stores the latest text so a sidecar restart replays it; the box clears when the session stops.

## Right-click transcript actions (2026-06-12)

Selected transcript text can be acted on directly: right-click → **Answer / Context / Fact check**. These are exactly the auto-classifier's kinds (`question`→answer, `context`, `factcheck`), gated by the same `config.triggers` toggles, so the manual menu and the automatic pipeline never diverge. Preferences posts `advisorConfigChanged` on save and the transcript view reloads its trigger toggles on receipt, so toggling a kind updates the menu live rather than only after a relaunch. The prompt templates live once in `trigger.ts` (`researchTask`/`cardKind`), shared by `drainResearch` and the manual path. The action rides the existing `query` lane (now carrying optional `action` + `triggerId`); `triggerId` anchors the resulting card under the clicked line, the same way auto cards anchor via the classifier's `anchorId`. The free-text Ask box still sends a bare `query` (kind `query`, no anchor) — unchanged.

Selection capture needs the real highlighted span, which SwiftUI's `Text` + `.textSelection` hides from a `.contextMenu`; the transcript line is therefore an `NSTextView` (`SelectableTranscriptText`) whose `menu(for:)` builds the action items over `selectedRange` (falling back to the whole line). Building it via the convenience `NSTextView(frame:)` (not a hand-assembled TextKit stack) so the view owns its text storage — a manual stack leaves storage/layoutManager unretained and they deallocate, blanking the line. The space-to-pause monitor now ignores only *editable* text views, so a focused (non-editable) transcript line still toggles playback.

**Dedup considered and dropped.** A first cut had a manual action supersede the equivalent in-flight auto card (cancel by matching anchor+kind, `card_remove` to hide it; register the subject in `covered`). Reverted after testing: auto-triggers anchor to the *last* line of the classifier window and subjects are fuzzy, so anchor/subject matching missed most real duplicates while adding protocol and state surface — a dedup that only sometimes fires invites false confidence. Manual and auto now run independently; the occasional duplicate is accepted (the user waits, then asks manually if nothing appears). Reliable dedup would need semantic subject matching — out of scope.

## In-card follow-up replies (2026-06-13)

A finished card grows a follow-up box; the answer is appended in place (`---` separator + `**You:**`/answer), so a card becomes a short thread rather than spawning new cards. **The sidecar stays stateless about cards** — it never retains card bodies. Instead the app's `card_reply` carries everything needed to answer in context: the card's current `body` (original answer + any prior turns), the new `replyText`, and a recent transcript slice (last ~15 lines, for resolving referents like "she"/"that"). `replyTask` in `trigger.ts` reconstructs the prompt, mirroring `researchTask` as the single source of truth.

The reply is answered by a **transient one-shot session** (`makeLane("reply", …)` then `reset()` in `finally`), created and disposed per follow-up. This is deliberate over reusing a research lane: the 1–8 lane pool is shared and would otherwise be drained by replies, and — because lanes are reused across unrelated triggers — a lane's session context would have drifted off-topic by the time the user replies. A fresh stateless session means clean context and no pool contention, at the cost of one SDK cold-spawn per reply (acceptable for a user-initiated action). `card_reply` has no `busy` gate and takes no pool slot, so it runs parallel to research. Streamed back as `card_update` on the same `cardId`; the sidecar reproduces the exact `base + **You:**` prefix the app shows optimistically, so the streamed body stays consistent.

A card carries an app-only `replying` flag (never on the wire): while a follow-up is in flight it hides both the reply box (so one card can't take two at once) and the cancel button, cleared when a terminal `card_update` arrives. The optimistic in-card edit is applied only if the `card_reply` send succeeds — if the sidecar is down the message is dropped and the card is left untouched, rather than spinning forever with no answer coming and no cancel.

## Packaging as a distributable .app (2026-06-13)

The dev build is a bare SwiftPM executable that locates the sidecar by `#filePath`-derived `repoRoot`. That doesn't survive leaving the checkout. `App/package.sh` now assembles a self-contained `Advisor.app`; `AppResources` resolves resources from `Bundle.main` when packaged and falls back to `repoRoot` in a dev checkout, so one binary runs either way.

Decisions (single-user, few-machine distribution — not the App Store): **bundle the Node runtime** (the ~127 MB arm64 `node` binary, copied into `Contents/Resources`) so the target needs no Node install; the Agent SDK's own child processes reuse it via `process.execPath`. **Ad-hoc signed, not notarised** (`codesign -s -`) — first launch needs right-click ▸ Open. STT is Apple SpeechAnalyzer, so there are no model files or native dylibs to ship — the bundle is just the executable, Node, and the built sidecar.

(Originally the bundle also flattened the whisper + ggml/Metal dylibs into `Contents/Frameworks` with rpath surgery; removed with whisper — see the dated section below.) The bundled Node boots the bundled sidecar with no system Node on `PATH`. The sidecar still needs the user's Claude Code login on the target.

## Codex as an alternative provider (2026-06-13)

Every lane — trigger classifier, research lanes, manual query lane — runs on **Claude** (Agent SDK) or **Codex** (`@openai/codex-sdk`), chosen in Preferences with a provider + model picker. (Originally per-component with a per-provider remembered model; collapsed to one shared `{provider, model}` later the same day — see the shared-backend note below.) The sidecar abstracts both behind an `Agent` interface (`run`/`reset`/`interrupt`); `AgentSession` is the Claude impl, `CodexAgentSession` (`codex.ts`) the Codex one. Both are long-lived, FIFO, context-retaining sessions. **Caveat (measured 2026-06-13): Codex is unfit for the research/query lanes** — ~5–7× slower than Claude and non-streaming (card stays empty until done). Keep research/query on Claude; see the latency-investigation section below.

**Provider registry (plug-in shape).** `providers.ts` holds a `PROVIDERS` registry mapping id → `{ label, create(opts) }`, and `createAgent(provider, opts)` resolves through it (unknown id → Claude, forward-compatible with newer configs). Adding a provider is one registry entry + one `Agent` class on the sidecar, and one `AgentProvider.all` entry (id, label, model list) in the app's `Preferences.swift` — the provider/model pickers are data-driven from that array, no per-provider branches. The two lists are mirrored across the language boundary by hand (Swift can't import the TS registry). The per-provider sandbox/tooling impl is irreducible — each SDK differs.

Auth follows the same principle as Claude — **no API key**: the Codex SDK reuses the user's Codex CLI login (`~/.codex/auth.json`). The platform binary ships transitively via `@openai/codex-sdk` → `@openai/codex` → `@openai/codex-darwin-arm64` in `node_modules`, so packaging needs no global `codex` install. Codex has no system-prompt parameter, so Advisor's system prompt is prepended to the first turn of each thread; later turns inherit it from thread context.

**Sandbox — deliberately coarser than Claude's, documented not hidden.** Claude runs under a per-call `canUseTool` policy (path denylist for reads, action-pattern gate for MCP). The Codex SDK exposes no per-call hook, so `CodexAgentSession` maps to `sandboxMode: "read-only"` + `approvalPolicy: "never"` (no writes, edits, escalation, or network-mutating commands), with web search + network enabled only when the component has a `Web*` tool (research/query yes, classifier no). Residual gaps versus Claude: a read-only Codex *shell* command can still read sensitive dotfiles (`~/.ssh` etc.) — there is no path denylist — and Codex MCP servers come from `~/.codex/config.toml`, so they are not gated by `allowMcpActions`. Accept for a single-user local tool; revisit if Codex gains per-tool callbacks.

**One shared backend, not per-component (2026-06-13).** The three independent lane choices (classifier, research, query) collapsed into one top-level `{provider, model}` used by every lane. Rationale: the per-component split was never used in practice — research and query already shared a model, and a separately-tuned classifier added a knob without a payoff. A scalar `model` (`""` = provider default) replaces the per-provider `models` map; switching provider now forgets the prior model (the UI resets it on change) rather than remembering one per provider. Consequence accepted: the classifier no longer defaults to Haiku — it follows the shared model (default Sonnet), trading a little classify latency/cost for a single knob. **No config migration** — still early testing, so a stale `config.json` is simply dropped (its unrecognised keys ignored, missing keys defaulted) rather than normalised. Both sides keep a tolerant decoder (sidecar `mergeConfig()`, Swift `init(from:)`) only so missing keys default instead of throwing.

## Latency investigation — progressive answers, warming, Codex unfit for research (2026-06-13)

First real-use complaint: 60 s+ from a spoken question to a useful card. Instrumented the whole pre-card path (per-stage + per-text-block latency logging in `agent.ts`/`main.ts`/`protocol.ts`, kept on permanently for ongoing tuning — each `[sidecar +Xs]` line is on one timeline). Findings, in order of impact:

- **Codex is unfit for the research/query lanes.** Measured the same question with research on Codex vs Claude/Opus: **Codex ~170 s, Claude ~25–34 s** — a 5–7× gap — and Codex emits nothing until the turn ends, so the card sits empty then pops. Claude streams text blocks as it writes. Keep research/query on Claude; Codex remains selectable (and fine for the classifier, whose output is a single JSON blob) but should not be the research/query backend. The earlier 170 s "agent is slow" symptom was almost entirely this misconfiguration, not the SDK.
- **Claude won't volunteer progressive output — it must be told.** Baseline (no instruction): Claude runs every tool then dumps one block; first text == final, ~24 s into the run. So the system prompt now mandates a **two-pass answer in one turn**: write a brief `From your notes:` preliminary from the local search *first*, then consult web/connectors and revise. With it, useful content reaches the card ~9 s into the run (~15 s earlier) for ~5 s more total. The prompt also **forbids narration** ("I'll check…") — the first block must be real content, or the early-content win is wasted on filler.
- **The local/web split was prototyped and rejected.** A throwaway spike fired a parallel local-only card (Read/Grep/Glob, no web) beside the web card. Local *started* faster (first text ~5 s) but *finished* slower (~38 s) — a heavy model doing many sequential `Read`s. The instructed single agent gives the same progressive feel with **one card and no second model**; the split's only real edge is parallelism, and gathering the local data (~15–20 s here) is the floor either way. Not worth the extra card/lane/model plumbing.
- **Cold-spawn warmed off the critical path.** The Agent SDK boots a CLI subprocess on the first `run()` of each session (~5–10 s; classifier Haiku measured cold 5.7–9.4 s). It was paid serially on the first question by both the classifier and the lead research lane. `session_start` now fires fire-and-forget warm-ups (`warmClassifier()` + a trivial run on `researchLanes[0]`) so the first real question skips both boots.

Remaining floor is STT finalisation (~8–12 s, app-side, separate) plus the unavoidable local-gather time. The ≤5 s aspiration in the latency budget above remains aspirational for agentic answers.

## Whisper removed (2026-06-14)

Whisper.cpp dropped entirely; Apple SpeechAnalyzer is now the only STT engine. In real use Apple won on every axis that mattered (streaming endpointing, no noise hallucination, near-vanishing echo), and the whisper path carried real cost: a vendored CMake/Metal build, the `CWhisper` C shim and header symlinks (`setup.sh`), ~6 native dylibs flattened into the bundle with rpath surgery, a 1.5 GB model to source, and the whole VAD `Segmenter` + decode-queue machinery. Removing it deleted `WhisperTranscriber`, `Segmenter`, `CWhisper`, `setup.sh`, the `--smoke` headless test (whisper-only), the `STTEngine` enum and its Preferences picker, and the `ADVISOR_WHISPER_MODEL` / model-path plumbing in `AppResources`.

The vocabulary/dictionary feature went with it: its sole purpose was biasing whisper's `initial_prompt`, and Apple's path has no equivalent hook — so `VocabularyStore`, the Dictionary preferences pane, and the right-click "Add to dictionary" submenu are gone. Supersedes the "STT engine switch" and "STT tuning findings" sections above. The historical reasoning there is kept as the record of how the engine choice evolved.

## Optional API-key auth (2026-06-14)

Subscription login (Claude Code / Codex CLI) stays the default, but a machine
with no CLI login can now authenticate with a provider API key — an **opt-in
fallback**, not a requirement (which the project constraints still forbid). A
Preferences **Authentication** toggle picks `subscription` vs `apiKey` for the
active provider; the key is held in the **macOS Keychain** (`Keychain.swift`),
never in `config.json`. In API-key mode the app reads the active provider's key
at sidecar spawn and injects it as an environment variable
(`SidecarManager.apiKeyEnv`): `ANTHROPIC_API_KEY` for Claude, `OPENAI_API_KEY`
for Codex.

The injection is the whole mechanism — the sidecar never sees the secret in
config. Claude needs **no sidecar change**: the Agent SDK's `query()` spawns the
`claude` CLI which inherits `process.env`, so the env key flows through (when set
it takes precedence over a stored OAuth login). Codex needs an explicit pass —
`codexConstructorOptions(process.env)` returns `{ apiKey }` only when
`OPENAI_API_KEY` is present, since a leftover ChatGPT login would otherwise win;
`env` is left unset so the Codex CLI still inherits the rest of `process.env`.
`authMode` is App-side only (like `sttLocale`) — deliberately absent from
`sidecar/src/config.ts`, because the sidecar acts purely on the injected env.
Supersedes the "no API key" lines in the packaging and Codex sections above.

**Key validation at entry (2026-06-14).** An invalid key previously failed
silently — it surfaced only as an "Invalid API key" research-lane error
mid-session. `AuthValidator` now tests a key directly against the provider's
models endpoint (Anthropic `x-api-key`, OpenAI bearer) when entered in
Preferences, showing inline status and an alert on rejection. The key field is a
visible rounded-border input.

## Listening view redesign (2026-06-14)

The Listening view was rebuilt to a high-fidelity handoff spec, keeping
behaviour but introducing the app's first design-token layer (`Theme.swift`:
semantic light+dark colour tokens via dynamic `NSColor`s, plus spacing/radius/
type-scale metrics). Decomposed into components: `ListeningToolbar` (record
cluster — waveform + timer + pause/stop + mic mute — audio-source menu, Context
chip, Auto-cards switch, Float, Export, Sessions; idle collapses to a single
Listen pill), `AskBar` (sparkle input + ⌘↵), and `ListeningCardView` (type/verdict
pill, Researching state, collapse/expand + dismiss, themed Markdown body,
trigger-quote + sources footer, follow-up input). The transcript is a centred
812 pt column with a day divider and flowing paragraphs that group consecutive
utterances, breaking only on a >1 s gap or an injected card, with a blinking
interim line.

Card-model changes: `isExpanded` (fact-checks collapse by default),
`triggerQuote` (derived from the anchor utterance), `sources` and `verdict`
(parsed when the sidecar emits them; absent for now); `toggleCard`/`dismissCard`
on the store. Pause now freezes the session timer (`sessionStart` shifted
forward by paused durations so elapsed excludes pauses); dismissing an in-flight
card cancels its research; the session note re-writes only on output-bearing
card changes. The session-prompt box moved from a fixed strip below the toolbar
into the Context-chip popover; mic mute moved into the record cluster.

The summarise control (a transient AskBar action) was removed shortly after —
post-meeting summaries remain out of scope (REQUIREMENTS).

### 2026-06-18 — Markdown export + one session format (inline cards)

A toolbar **Export** button (share icon, left of Sessions) shares the current
session note via `NSSavePanel`. Rather than give export its own renderer, the
**session note format was unified** on the inline layout (`SessionMarkdown.inline`):
utterances and finished cards merge chronologically (a card sorts after an
utterance at equal time, the same ordering the live feed uses), each card a
`>`-quoted "chat" block — `LABEL · Title`, body, then a grounding/trigger-quote +
sources footer — so the saved note reads like the window. Export is then trivial:
flush + copy the on-disk file (`SessionWriter.export`).

This **dropped the footnote format** (the prior `[^card-N]` line↔card backlinks
for Obsidian/GitHub, plus the "Other cards" orphan section). Trade accepted: one
format and far less code over backlink navigation; orphan/query cards now place
chronologically by `created` time instead of in a trailing section. Nothing
parses these files (write-only archival), so no migration — old notes keep their
old format. `SessionMarkdown` is a pure function, covered by the project's first
unit tests (`Tests/AdvisorTests`, swift-testing).

### 2026-06-18 — Sessions browser (master/detail) + ask-and-append

The **History** button (clock icon) opens the **Sessions** window (`SessionsView`,
a single `Window(id: "sessions")` with `.hiddenTitleBar`) — a master/detail
browser over saved notes, per `design_handoff_advisor/SESSIONS.md`. `SessionArchive`
lists `~/Library/Application Support/Advisor/sessions/*.md`, parsing the
`yyyy-MM-dd-HHmmss.md` name to a date (the filename formatter + on-disk location,
previously private to `SessionWriter`, moved here so both share one source of
truth). Left: search + an All / This week filter + a date-grouped list (Today /
Yesterday / Earlier this week / This month / Earlier); each row shows title, gist,
time, duration and card count, with the selected row a white card + blue accent
bar. Right: the selected session — title, meta line, the questions asked of it,
and the full transcript (cards inline, as in the live feed) — plus the ask bar.
(Starting a recording stays in the Listening window's toolbar, not duplicated
here.)

**Scope: layout + real data only.** Everything rendered comes from the saved
notes. The handoff's AI-derived fields (category badge, topic chips, summary,
people, action items) and star / Resume are deliberately **not** built yet — they
need new generation, protocol changes and per-session storage. Two deviations from
the handoff, both deliberate: (1) the handoff wants Sessions and Listening as two
destinations of *one* window (`NavigationSplitView`); fully merging them safely
means hoisting the recorder/sidecar/writer lifecycle out of `TranscriptView` (it
rebuilds on `.task`, so a naïve swap would respawn the sidecar each visit), a large
refactor — Sessions is its own window for now (the handoff allows "your existing
navigation"). (2) Titles come from the **session context** the user types before
Listen, now persisted to the note's frontmatter (`SessionMarkdown.inline` writes
`context:`, collapsed to one line; `SessionWriter` carries it, updatable
mid-session), with a date fallback for untitled/old notes.

**Optionally naming a session.** A session can be given an explicit `name:`
(frontmatter), which wins over `context` as the browser title — context steers
research and is often verbose or empty, so a short label keeps the list scannable
(`SessionDetail` precedence: name → context → date). Set two ways: **before/during
a live session** from the toolbar's Context popover (a Name field beside the
context box — seeded into the writer at `start`, edited live via `updateName`,
gated on `sessionActive` like context so the stop-time blank can't wipe it), or
**after the fact** from the Sessions detail (the `…` menu → Rename). Two write
paths mirror the two-writer split: the **live/just-finished note** (still owned by
`SessionWriter`) is renamed *through* the writer (browser rename calls
`renameOwnedNote`, which sets the name and flushes; live edits ride the normal
debounced write) — a direct frontmatter write would be clobbered when a late
research card finishes; **any other saved note** is edited on disk via
`SessionArchive.setName` (a pure `settingName` frontmatter editor that inserts/
replaces/removes the key while preserving body and follow-ups). The browser
reaches the live writer through `TranscriptWindowContext`, the same bridge it uses
for the live sidecar.

**Rendered like the live window, not as raw markdown.** The saved format is a
timestamped bullet list with `>`-quoted cards, so rendering it via `MarkdownUI`
read nothing like the live feed. `TranscriptDoc` reconstructs display blocks —
the inverse of `SessionMarkdown.inline`: consecutive transcript lines join into
flowing paragraphs (new paragraph when the inter-line gap exceeds 2 s, matching
the live feed's collapsing; blank lines between entries do **not** split, since
`inline` blank-separates every entry), blockquotes become cards. Paragraphs render
through the same `SelectableTranscriptText` the live view uses (no AI actions);
card blocks render in live card chrome. `SessionDetail.parse` layers on top,
splitting the card blocks into "surfaced cards" vs "you asked" (a `Q ·` label) and
deriving title/gist/timing. Pure parsers, unit-tested (`TranscriptDocTests`,
`SessionDetailTests`).

**Asking runs on its own isolated path, not the live query lane.** The query lane
is bound to live-session state (the rolling transcript-delta cursor, the session
prompt, the single `busy` gate), so routing a question about a *saved* document
through it would pollute the live conversation's context and serialise against
live queries. Instead `ask_document` carries the whole note as a self-contained
`document` and is answered by a **transient one-shot session** — the same pattern
as `card_reply` (`makeLane("document")` then `reset()` in `finally`): no pool
slot, no `busy` gate, no live-session state, parallel-safe, works mid-session.
Streamed back as `document_answer` keyed by request id; `SidecarManager` routes
each frame to a per-id handler registered by `askDocument` (kept out of the live
`store.cards`) and drops it on a terminal state. Concurrent document questions
are capped (2) like replies, so a burst can't fork unbounded SDK subprocesses.

On `done` the answer is appended to the note under a one-time `# Follow-ups`
heading as a `>`-quoted block matching the inline-card style
(`SessionMarkdown.followUpBlock`), then the view reloads from disk — so the saved
transcript grows with the questions asked of it.

**Two-writer hazard, guarded.** `SessionWriter` rewrites its note wholesale (a
2 s debounced re-render from the store) and keeps owning its `fileURL` after
`end()` (late research cards still land in the file). A follow-up append to that
same file would be clobbered by the next debounced rewrite. The detail pane
therefore refuses to ask about **any file the live writer still owns**
(`writer.currentFileURL`, not merely "while listening") — the just-ended session
becomes askable once the next session starts or the app restarts. Because the
Sessions window is a sibling scene (not a child of the live view), it can't
receive the sidecar/owned-file as params; `TranscriptWindowContext` (a
`@MainActor` shared holder the live view populates) carries both across scenes.
Residual limitations (accepted for a single-user local tool): an `ask_document`
whose sidecar dies mid-stream leaks its handler and the pane stays "asking"
(parity with `card_reply`); the list refreshes on open and on
`.advisorSessionsChanged` (posted when a session starts or ends).

## Appearance preference (2026-06-18)

Light/dark/system picker in Preferences (issue #3). `config.appearance`
("system"|"light"|"dark") is App-side only — deliberately absent from the
sidecar config (like `sttLocale`/`authMode`), since appearance is pure UI.
`AppDelegate` sets `NSApp.appearance` (nil for "system", `.aqua`/`.darkAqua`
otherwise) at launch and again on every `.advisorConfigChanged` post, so the
change lands without a relaunch. The Theme's colours are already dynamic
NSColors resolved against `NSApp.effectiveAppearance`, so forcing the app
appearance drives the whole UI for free — no per-view `.preferredColorScheme`.

## Sessions as the main window (2026-06-19, issue #4)

The app now opens on the **Sessions** browser, not the live feed. `SessionsView`
is the first scene — a `Window(id: "sessions")` with `.defaultLaunchBehavior(.presented)`.
A new recording is started with **Cmd-N** (see issue #11 below). The
recording window (`TranscriptView`) is a separate `Window(id: "recording")`
(`.defaultLaunchBehavior(.suppressed)`, `.restorationBehavior(.disabled)`); being a
`Window` (not a `WindowGroup`) makes it single-instance for free — New just brings
the existing one forward, satisfying "only one recording window at a time".

This forced the **service-lifecycle hoist** the 2026-06-18 Sessions-browser entry
deferred. The sidecar and writer can no longer live in `TranscriptView.setup()`:
if the recording window is the only thing that starts them, the Sessions browser
couldn't answer questions about saved transcripts before a recording window ever
opened. A new `AppServices` (`@MainActor ObservableObject`, the `@StateObject` in
`AdvisorApp`) owns the **app-lifetime** trio — `store`, `sidecar`, `writer` —
constructed in its `init` (so the `@StateObject`-can't-reference-another-`@StateObject`
rule never bites) and started once from the Sessions scene's `.task`. It publishes
`sidecar`/`writer` into the existing `TranscriptWindowContext` bridge, so
`SessionsView` is unchanged. The **`Recorder`** (the audio device) stays
window-owned — built on demand by the recording window — and `AppServices` holds it
only `weak`, purely so the terminate cleanup (`onTerminate`, registered once in
`start()`) can stop it before `_exit(0)`.

**Close = clean stop.** Closing the recording window mid-session ends *that*
session — `onDisappear` runs the stop branch (stop audio, `session_end`,
`writer.end()`) but never `sidecar.stop()`, so the shared sidecar survives. It then
clears the app-lifetime store so a reopened window starts blank.

**Close guard for in-flight agents (2026-06-19, issue #7).** Ending the session
doesn't stop the research/query agents it already dispatched — they finish on
their shared lanes after the window is gone. `WindowCloseGuard`
(`SessionClose.swift`) intercepts the close to handle this. It's a zero-size
`NSViewRepresentable` that makes a coordinator the window's `NSWindowDelegate`,
proxying SwiftUI's own delegate (forwarding every message except
`windowShouldClose`). On close, if any card is still researching
(`store.cards.contains { $0.isResearching }` — covers research, query and reply
agents) it prompts: **Wait** stops recording and polls until the in-flight cards
reach a terminal state, flushes the note, drops the overlay, then closes via
SwiftUI's `dismissWindow(id:)`. While waiting, a blocking `finishingOverlay`
covers the window and the live UI is `.disabled` — and the Space key monitor is
dropped — so the about-to-close window can't be driven (Space would otherwise start
a fresh session, recording having stopped); the overlay's **Stop now** button
cancels the remaining agents to close at once. The guard ignores any close attempt
while `finishing` is set (the `isFinishing` closure), so the wait can't re-prompt.

Two traps the single-instance `Window` sprang here, both fixed: it keeps the
recording view's **`@State` across close/reopen**, so the `finishing` flag is reset
in `onDisappear` (and before the dismiss) or a "Wait"-close would leave a stale veil
over the *next* session; and **`NSWindow.close()` did not fire SwiftUI's
`onDisappear`**, so the wait's close goes through `dismissWindow` instead —
otherwise the session's clean-stop (`releaseNote`, store-clear) was skipped and the
previous session leaked into the new one. **Stop and Close** cancels each
in-flight
card (`sendCancel`, marked `cancelled` locally so the final write records it) and
closes; **Cancel** keeps the window open. Nothing running → closes straight away,
as before. The sidecar is never stopped — only this session's tasks — so the
Sessions browser keeps working. The pure choice→action map (`SessionClose.action`)
is unit-tested; the AppKit plumbing is exercised by hand. Cmd-Q still bypasses all
of this via `applicationShouldTerminate` (which `sidecar.stop()`s, killing the node
child and every agent with it).

**Trailing-STT bleed across sessions (2026-06-19).** Closing and quickly reopening
showed fragments of the previous conversation in the new session. Cause:
`AppleSpeechEngine.stop()` calls `finalizeAndFinishThroughEndOfInput`, which flushes
buffered audio as *trailing finals*, and `acceptAsync` defers `me` results by up to
1.5 s for echo dedup — so finals land in the **shared, app-lifetime** `store` after
the window closed, and the old `Recorder` lingers because its in-flight closures
retain it. Fix: a **session token**. `TranscriptStore.sessionGeneration` bumps on
each `Recorder.start()`; the token is passed into `AppleSpeechEngine.start` and
tagged onto every result it emits (`onFinal`/`onVolatile` carry it), threaded
through `acceptAsync`/`accept`, and **checked at the actual store write** on the
main actor — the write is dropped when the token no longer matches. This beats a
"stopped" flag (a first attempt): a reused recorder's reset would re-arm before a
1.5 s-delayed `me` final fired, and an already-queued callback had no late check.
The token is fixed at capture, so a previous session's straggler is dropped whether
the recorder is reused (fast Stop→Listen) or a fresh recorder writes to the same
shared store (close→reopen). The generation bumps at **every store reset that
starts a blank view** — synchronously in `toggle`'s start branch (before the clear
and any `await`, closing the race) and in the recording window's `onDisappear`
(which also runs atomically on the main actor) — but **not** on a plain Stop, so a
just-stopped session still shown in its window keeps receiving its own trailing
finals. The close bump is the one that fixed the reported bleed: without it, a
closed session's still-processing finals matched the unchanged generation and
appended to the blank store the next window showed.

**Auto-classifier outliving the session (2026-06-19).** `session_end` cleared only
the debounce timer, so a classify already scheduled or mid-flight could still
enqueue research and stream cards into a closed/replaced session (the close prompt's
`agentsInFlight` can't see a classify that hasn't emitted a card yet). Fix: a
`sessionActive` flag in the sidecar — set on `session_start`, cleared on
`session_end` (which also drops the queued-but-undispatched `researchQueue`).
`scheduleClassify`/`runClassify` bail when it's false, including a re-check after the
classify await. In-flight research lanes keep running — the close prompt waits for or
cancels those; only *new* auto-work is suppressed. User queries (Ask box, right-click)
are deliberately ungated, so they still work after Stop.

**Cancel now reaches reply agents (2026-06-19).** Card-reply follow-ups run on a
transient lane outside `researchLanes`/`queryLane`, and the `cancel` handler only
searched those two — so "Stop and Close" marked a reply card cancelled locally while
its agent kept running in the shared sidecar. Fix: track in-flight reply lanes
(`replyLanes`, keyed by `currentCardId`), include them in the cancel search so the
session is interrupted, and guard `runCardReply`'s streamed/terminal sends with
`cancelledCards` like `runCard` does.

**The store-clear hazard, guarded.** Clearing the *shared* store while the writer
still owned its just-saved note was a data-loss trap: `SessionWriter` rewrites the
note wholesale from the store, and `end()` keeps `fileURL` (late cards land in the
file), so the app-terminate flush — or the store-clear's own debounced rewrite —
would serialise the emptied store over the saved note. The fix is
`SessionWriter.releaseNote()`: on window close (after the final `end()` flush) it
nils `fileURL`/`started`, so `write()`'s existing `guard let fileURL, let started`
no-ops every later rewrite. `liveFileURL` is dropped at the same point, so the
finished note is handed off to disk-based management (the browser renames/queries
it via `SessionArchive`, not the now-detached writer) — which also releases the
two-writer ask-lock immediately on close instead of waiting for the next session.

## Delete sessions (2026-06-19, issue #8)

**Delete** lives in the detail pane's `…` menu (below Rename/Export/Reveal, after a
divider, `role: .destructive`), behind a confirmation alert — the note is removed
from disk, irreversible. It sits with the other note actions rather than as a
per-row icon (tried a row trash icon first; it crowded the cell). The delete itself
is one line — `SessionArchive.delete` (`removeItem`, returns false rather than
throwing) — and the browser's notification-driven `reload()` already reconciles the
selection when the open session goes away. The live (still-writing) session is
exempt: its `SessionWriter` would just recreate any note deleted out from under it,
so the menu item is `disabled(isLive)`.

## Resume after stopping; Pause removed (2026-06-19, issue #6)

**Stop is now resumable, and Pause is gone.** Pause kept the audio engines alive
and merely dropped incoming samples; Stop tore everything down and ended the
session. The two overlapped, so Pause was removed and Stop took on its role: Stop
tears down the audio engines (releasing the mic + ScreenCaptureKit stream) but
leaves the *session* live — no `session_end`, no `writer.end()`, `sessionStart`
retained. The record cluster then shows a frozen-timer **Resume** control that
restarts audio into the **same** session: no STT generation bump (so existing
utterances stand), no new `session_start` (so the sidecar classifier keeps full
context), no new note. The timer excludes stopped spans the way it used to exclude
paused ones (`sessionStart` shifted forward by the stop's duration on resume —
`RecordControl.resumedStart`).

A session is therefore finalised only when the **recording window closes** (or the
app terminates): the close path ends the session whenever one is in progress
(`sessionStart != nil`), not only when audio is live. Consequence: in-window
Stop→Listen no longer starts a fresh session — a new session means closing the
window and opening a new one from the Sessions browser, matching the
single-session-per-window model. The toolbar's three states (idle Listen pill /
recording cluster / resumable cluster) and the resume timer maths live in the pure
`RecordControl` helper (unit-tested, mirroring `SessionClose`); the Space monitor
maps the same three states to start/stop/resume. `store.paused`, the recorder's
`paused` atomic, and `Recorder.pause()/resume()` were deleted.

## Pre-canned contexts (2026-06-19, issue #10)

A library of named, reusable session contexts. A `SavedContext {id, name, text}`
list lives in `config.json` as `contexts` — App-side only data, decoded
tolerantly and **ignored by the sidecar** (its `mergeConfig` reads keys
field-by-field; the sidecar only ever receives the resolved context *text* per
session, like `appearance`/`sttLocale`/`authMode`). Pure list operations
(`ContextLibrary.saving` by name, `.upserting` by id, `.removing`) are
unit-tested; the SwiftUI views are thin wrappers over them.

Managed in three places, kept in sync via the existing `advisorConfigChanged`
post: **Preferences** has a "Saved contexts" section (list + add/edit/delete
through a sheet editor, committing by id so a rename can't spawn a duplicate);
the **recording window's Context popover** gains **Load** (pick a saved context
into the box) and **Save…** (store the current text under a name, upserting by
name). The recording window persists via `AdvisorConfig.persistContexts`, a
load-modify-save that touches only the `contexts` key so it can't clobber
preference settings it doesn't hold in view state. Because contexts are now
editable from two windows, `PreferencesView` also pulls on-disk context changes
back in on `advisorConfigChanged` (guarded on inequality, so it never reacts to
its own posts — no save loop), and the recording window reloads its library on
the same post. Trade accepted (single-user tool): the Preferences "Add" path
commits by id, so typing an already-used name there yields two same-named
entries that the by-name recording-window Save can't disambiguate.

## Cmd-N, no Sessions title panel (2026-06-19, issue #11)

Dropped `SessionsView`'s custom 52pt title panel (the "Advisor · Sessions"
heading + **New** button). Starting a recording is now **Cmd-N**, wired as a
`RecordingCommands: Commands` that `CommandGroup(replacing: .newItem)` (the
shortcut belongs in the menu bar, and there's no document to "new"). It's a
`Commands` type rather than inline `.commands {}` so it can read `openWindow`
from the environment, which the `App` struct can't. The Sessions window keeps
`.hiddenTitleBar`; with the panel gone its traffic lights now overlay the
sidebar's top-left, so the search/filter block gains `.padding(.top, 38)` to
clear them. The top strip stays draggable (hidden title bar) and `openWindow`'s
single-instance `Window` semantics are unchanged — Cmd-N just brings an existing
recording window forward.

## Session tags (2026-06-20, issue #15)

Sessions can carry tags. A **tag library** (name + colour) lives in
`config.json` as `tags: [SavedTag]` — App-side only, like `contexts`, so the
sidecar never sees it (`TagLibrary` holds the pure upsert/remove/lookup ops).
Tags are managed in **Preferences ▸ Tags** (add / recolour / delete) and
*applied* to a session from a **Tags chip** — present on both the live recording
toolbar and the Sessions browser detail header (the "both surfaces" choice). The
chip's popover is a pick-list of the library's tags (no free-text entry, no
colour there): you assign existing tags only, because creation + colour belong in
one place (Preferences).

A session stores its tags **by name** in note frontmatter (`tags: a, b, c`, one
collapsed line — the same scalar shape as `context`, formatted by the single
`SessionArchive.tagsLine`, which trims, squashes the comma/newline separators out
of names, and de-dups case-insensitively). Colour is resolved at render time by
looking the name up in the library, which has three consequences we leaned into:

- **Delete is cheap and matches the issue's "just removes them from each card":**
  rows render only library-known tags, so deleting a tag in Preferences makes its
  pills vanish everywhere without rewriting a single note.
- **Rename propagates** so the name reference doesn't orphan. Editing a tag's
  name (`SessionArchive.renameTag`) rewrites that tag across every *saved* note's
  frontmatter; the *live* note is skipped on disk and renamed through its writer,
  driven by the `advisorTagRenamed` notification the recording window observes
  (which remaps its staged `sessionTags`, cascading to `setOwnedNoteTags`). The
  editor blocks a rename that would collide with another tag's name. Mass-rewrite
  is synchronous — fine for a personal archive; revisit if it ever gets large.
- Pills are drawn by a shared `TagPill` (colour text on a low-opacity capsule, so
  one stored hex reads in both light and dark) laid out by a small `FlowLayout`
  (SwiftUI has no built-in flow); colours come from a preset swatch palette in
  `Theme`, stored as `0xRRGGBB` strings.

Persistence mirrors `name`/`rename`: a *saved* note is tagged by a direct
frontmatter write (`SessionArchive.setTags`); the *live/just-finished* note is
tagged through the writer (`SessionWriter.setOwnedNoteTags`, ungated like
`renameOwnedNote`) so a late card-finish rewrite can't clobber it. Because that
path is ungated, `endSession` nulls `sessionStart` *before* clearing the staged
`sessionTags`, or the clear's `onChange` would flush empty tags over the saved
note. Search includes tag names in the browser's haystack, and a `#tag` token
(`SessionSearch`) filters by tag specifically rather than matching any transcript
word.

## Choosable transcript folder (2026-06-20, issue #16)

Where session notes live is now a preference. `config.json` gains `sessionDir`
(App-side only, like `sttLocale`/`contexts`/`tags` — only the app reads or writes
notes, so the sidecar never sees it): `""` means the built-in default
(`Application Support/Advisor/sessions`), otherwise an absolute path.
`SessionArchive.directory` reads it **fresh** each access
(`directory(for: AdvisorConfig.load().sessionDir)` over a pure resolver split out
for testing), so a folder change applies without an app relaunch. The
launch-lifetime `SessionWriter` is the subtle case: it would otherwise pin the
launch-time folder, so it resolves the directory **at each `start()`** (injected
resolver, defaulting to `SessionArchive.directory`) rather than caching it at
`init` — every new session lands in the *current* folder. The browser's `list()`
reads it per notification-driven `reload()`. Resolution is the only hot use and
the config file is tiny, so re-reading beats caching + invalidation.

**Preferences ▸ Session storage** shows the resolved path with a **Change…**
button (`NSOpenPanel`, directories only, create allowed). On a new pick, if the
old folder holds transcripts the user is offered **Move / Leave Them / Cancel**
(`SessionArchive.move` — relocate the session `.md`, create the dest, never
clobber a name collision, ignore non-session files; synchronous, like
`renameTag`). `move` returns `(moved, skipped)`: a partial/failed move would
split the archive across two folders, so the switch isn't silent about it — a
total failure (nothing moved) keeps the old folder, and a partial move reports
what stayed behind before still switching to where the bulk now lives. Writing
`config.sessionDir` rides the form's existing `onChange` → `save()` +
`advisorConfigChanged`, which the Sessions browser already reloads on, so it
re-lists from the new folder for free.

The **live** note is excluded from the move (like `delete`/`renameTag`): the
still-writing session already resolved its `fileURL` in the old folder at
`start()`, and a debounced rewrite would recreate any file moved out from under
it. Consequence (accepted, not fought): a session recording *across* the change
keeps writing to the old folder — it won't appear in the browser (now listing the
new folder) until it ends and — if ever — the folder is pointed back. New
sessions started after the change use the new folder, so this only affects an
in-flight recording; blocking the change mid-session was considered and dropped
as over-scoped.

## Session list right-click menu (2026-06-21, issue #20)

The browser list rows get a `.contextMenu` with the same four actions as the
detail pane's `…` menu — Rename / Export / Reveal in Finder / Delete — so you can
act on a session without first selecting it. The menu acts on the *right-clicked*
row (the `LoadedSession` captured in the closure), not the selected one, so its
Rename/Delete alerts are presented against optional `renaming`/`deleting` row
state in `SessionsView`, separate from the detail pane's own alert state.

The shared part is the *actions*, not the menu chrome: `renameSession` /
`deleteSession` / `exportSession` are file-private `@MainActor` free functions in
`SessionsView.swift`, called by both surfaces, so the live-note handling (rename
routes through the writer; delete is `disabled` for the live note) can't diverge.
Export now reports failures via an `NSAlert` modal rather than the detail pane's
inline `askNote`, since the row has no such inline surface — one error path for
both. This keeps the "actions belong in a menu, not per-row icons" decision from
the Delete section above, just adding a second way to open that menu.

## Revisit as it grows

Echo suppression approach (M2 will tell); Haiku trigger cost at daily use; markdown vs SQLite once history is large; exposing an MCP server over past sessions (the hybrid from REQUIREMENTS).
