# Advisor — Design

**Status:** Draft v1 — 2026-06-11
**Input:** [REQUIREMENTS.md](REQUIREMENTS.md)

## Overview

Two processes on one machine:

```
┌─────────────────────────── Swift app ────────────────────────────┐
│                                                                  │
│  AudioCapture ──► Transcription ──► SessionStore (markdown)      │
│   mic: AVAudioEngine   whisper.cpp        │                      │
│   sys: ScreenCaptureKit  (Metal, VAD)     ▼                      │
│                            │         OverlayUI (NSPanel)         │
│                            │              ▲                      │
│                            ▼              │ cards/results        │
│                      SidecarManager ──────┘                      │
└────────────────────────────┼─────────────────────────────────────┘
                   NDJSON over stdio
┌────────────────────────────┼──────────────── TS sidecar ─────────┐
│                            ▼                                     │
│  TriggerDetector (Haiku) ──► ResearchAgent (Claude Agent SDK)    │
│                               tools: web search, Vault (RO),     │
│                               Jira/Confluence/Slack MCP, files   │
└──────────────────────────────────────────────────────────────────┘
```

The Swift app owns everything realtime and visual; the sidecar owns everything that thinks. Only text crosses the boundary.

## Components

### Swift app

**AudioCapture.** Two concurrent sources: mic via `AVAudioEngine` tap; system audio via `ScreenCaptureKit` (`SCStream` audio-only, macOS 13+). Each resampled to 16 kHz mono PCM into a ring buffer, tagged `me` (mic) / `them` (system). Echo risk (own voice on both channels during calls): suppress `mic` segments that overlap >80 % in time with near-identical `sys` text; revisit if insufficient.

**Transcription.** whisper.cpp via C bindings, Metal. Energy/Silero VAD segments speech; each segment (cap ~6 s, 0.5 s overlap) transcribed off the audio thread, one decode queue per source. Model: `small` to start; `large-v3-turbo` if M0 spike shows headroom. Emits `Utterance{id, source, text, t0, t1}`.

**SidecarManager.** Spawns the Node sidecar and supervises it: on a crash it restarts with exponential backoff (1/2/4/8 s, capped 8 s, ≤5 attempts; a crash that follows a >60 s healthy run resets the budget, so only a tight loop exhausts it), then replays the session context the running conversation depends on — `session_start` plus the lane/auto config (not the utterance history; the classifier session is gone, so new utterances resume in a fresh sidecar session). A deliberate `stop()` is distinguished from a crash and cancels any pending restart. Sends to a dead sidecar surface on the status line rather than failing silently; budget exhausted → status asks the user to stop and start listening again. Transport: newline-delimited JSON over stdin/stdout. Chosen over WebSocket: no port management, lifecycle tied to parent, trivially debuggable. Logs on stderr.

**OverlayUI.** Non-activating `NSPanel` (`.floating`, `.nonactivatingPanel`) hosting SwiftUI: vertical card feed (newest top), collapsible live transcript drawer, query box, listening indicator + cost ticker. Menu-bar item: start/stop listening, open session history. Panel never takes key focus except when the query box is clicked.

**SessionStore.** One markdown file per session in `~/Library/Application Support/Advisor/sessions/YYYY-MM-DD-HHmmss.md` (second precision, so a same-minute restart can't overwrite the prior transcript): YAML frontmatter (start/end, cost), transcript section, cards section (type, body, sources). Each card is emitted as a Markdown footnote whose `[^card-N]` reference rides the transcript line that triggered it (via the card's `trigger` utterance id), so Obsidian/GitHub render a bidirectional link between line and card; cards with no anchor (Ask-box/query) fall into an "Other cards" section. Written incrementally; transcripts only, no audio (decided). Vault is never written.

### TS sidecar (Claude Agent SDK)

**TriggerDetector.** Maintains rolling transcript window (~2 min). On each utterance (debounced 1.5 s of silence-or-topic-shift), one Haiku call classifies: `question | entity | claim | none` + extracted subject. Dedup: don't re-trigger on a subject already carded in the last 10 min.

**ResearchAgent.** Per trigger, an Agent SDK query with budget caps (max turns ~6, streaming). Tools: web search; read-only filesystem MCP rooted at `~/Documents/Notes` and configured repo dirs; Atlassian + Slack MCPs. System prompt per trigger type (answer / context / fact-check). Fact-check answers must cite or return "couldn't verify" — never guess. Emits card immediately as placeholder, then streams body updates.

**QueryHandler.** F14 on-demand queries: same agent, full current-session transcript as context, results stream to a pinned card.

## IPC contract (NDJSON, one object per line)

Swift → sidecar:

```json
{"type":"session_start","sessionId":"...","ts":...}
{"type":"utterance","id":"u123","source":"them","text":"...","t0":...,"t1":...}
{"type":"query","id":"q7","text":"...","action":"answer|context|factcheck","triggerId":"u123"}
{"type":"card_reply","cardId":"c9","kind":"answer","title":"...","base":"<card's current body>","replyText":"...","transcript":"them: ...\nme: ..."}
{"type":"session_end"}
```

Sidecar → Swift:

```json
{"type":"card","id":"c9","trigger":"u123","kind":"answer|context|factcheck|query","title":"...","body":"...","sources":[{"title":"...","url":"..."}],"state":"pending|streaming|done|failed","confidence":"high|medium|low"}
{"type":"card_update","id":"c9","body":"...","state":"streaming"}
{"type":"usage","sessionCostUsd":0.42}
{"type":"error","fatal":false,"message":"..."}
```

Versioned with a `hello` exchange at startup.

## Latency budget (best efforts; ≤5 s utterance → useful card is the aspiration)

| Stage | Budget |
|---|---|
| VAD endpoint detection | 0.3 s |
| Whisper segment decode | 0.5–1.0 s |
| Trigger classify (Haiku) | 0.5 s |
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

Advisor no longer knows about the vault: agents load the user's own Claude config (`settingSources: ["user"]` → `~/.claude/CLAUDE.md`), which carries personal context like note locations. Verified: Patchwork vault query answered with no vault path in Advisor. Preferences (⌘,) write `Application Support/Advisor/config.json`, re-read by the sidecar at each session_start (sessions rebuilt so prompt/model changes apply): the research agents' editable persona/style prompt + extra instructions, trigger sensitivity + per-kind toggles + max per pass, classifier/research models, STT locale. The system prompt splits into an **editable persona** (`config.personaPrompt`, mirrored both sides) and a **protected operational core** (`sidecar/src/prompts.ts` — two-pass answering, no-narration, citation rules) the user cannot edit, so persona tweaks can't break card latency/format. A **session prompt** field steers a single session: filled before Listen (seeded via `session_start`) and editable mid-session (`session_context` messages). Because the persistent research/query lanes fix their system prompt at session start, the session prompt is injected **per task** (`sessionContextPrefix`, prepended to each research/query/reply dispatch and read fresh) rather than into the system prompt — so a live edit lands on the next card without rebuilding lanes. The app stores the latest text so a sidecar restart replays it; the box clears when the session stops.

## Right-click transcript actions (2026-06-12)

Selected transcript text can be acted on directly: right-click → **Answer / Context / Fact check**. These are exactly the auto-classifier's kinds (`question`→answer, `context`, `factcheck`), gated by the same `config.triggers` toggles, so the manual menu and the automatic pipeline never diverge. Preferences posts `advisorConfigChanged` on save and the transcript view reloads its trigger toggles on receipt, so toggling a kind updates the menu live rather than only after a relaunch. The prompt templates live once in `trigger.ts` (`researchTask`/`cardKind`), shared by `drainResearch` and the manual path. The action rides the existing `query` lane (now carrying optional `action` + `triggerId`); `triggerId` anchors the resulting card under the clicked line, the same way auto cards anchor via the classifier's `anchorId`. The free-text Ask box still sends a bare `query` (kind `query`, no anchor) — unchanged.

Selection capture needs the real highlighted span, which SwiftUI's `Text` + `.textSelection` hides from a `.contextMenu`; the transcript line is therefore an `NSTextView` (`SelectableTranscriptText`) whose `menu(for:)` builds the action items over `selectedRange` (falling back to the whole line). Building it via the convenience `NSTextView(frame:)` (not a hand-assembled TextKit stack) so the view owns its text storage — a manual stack leaves storage/layoutManager unretained and they deallocate, blanking the line. The space-to-pause monitor now ignores only *editable* text views, so a focused (non-editable) transcript line still toggles playback.

**Dedup considered and dropped.** A first cut had a manual action supersede the equivalent in-flight auto card (cancel by matching anchor+kind, `card_remove` to hide it; register the subject in `covered`). Reverted after testing: auto-triggers anchor to the *last* line of the classifier window and subjects are fuzzy, so anchor/subject matching missed most real duplicates while adding protocol and state surface — a dedup that only sometimes fires invites false confidence. Manual and auto now run independently; the occasional duplicate is accepted (the user waits, then asks manually if nothing appears). Reliable dedup would need semantic subject matching — out of scope.

## In-card follow-up replies (2026-06-13)

A finished card grows a follow-up box; the answer is appended in place (`---` separator + `**You:**`/answer), so a card becomes a short thread rather than spawning new cards. **The sidecar stays stateless about cards** — it never retains card bodies. Instead the app's `card_reply` carries everything needed to answer in context: the card's current `body` (original answer + any prior turns), the new `replyText`, and a recent transcript slice (last ~15 lines, for resolving referents like "she"/"that"). `replyTask` in `trigger.ts` reconstructs the prompt, mirroring `researchTask` as the single source of truth.

The reply is answered by a **transient one-shot session** (`makeLane("reply", …)` then `reset()` in `finally`), created and disposed per follow-up. This is deliberate over reusing a research lane: the 1–8 lane pool is shared and would otherwise be drained by replies, and — because lanes are reused across unrelated triggers — a lane's session context would have drifted off-topic by the time the user replies. A fresh stateless session means clean context and no pool contention, at the cost of one SDK cold-spawn per reply (acceptable for a user-initiated action). `card_reply` has no `busy` gate and takes no pool slot, so it runs parallel to research. Streamed back as `card_update` on the same `cardId`; the sidecar reproduces the exact `base + **You:**` prefix the app shows optimistically, so the streamed body stays consistent.

A card carries an app-only `replying` flag (never on the wire): while a follow-up is in flight it hides both the reply box (so one card can't take two at once) and the cancel button, cleared when a terminal `card_update` arrives. The optimistic in-card edit is applied only if the `card_reply` send succeeds — if the sidecar is down the message is dropped and the card is left untouched, rather than spinning forever with no answer coming and no cancel.

## Packaging as a distributable .app (2026-06-13)

The dev build is a bare SwiftPM executable that locates the sidecar and whisper model by `#filePath`-derived `repoRoot`, and links the whisper dylibs by absolute rpath into `vendor/whisper.cpp/build`. None of that survives leaving the checkout. `App/package.sh` now assembles a self-contained `Advisor.app`; `AppResources` resolves resources from `Bundle.main` when packaged and falls back to `repoRoot` in a dev checkout, so one binary runs either way.

Decisions (single-user, few-machine distribution — not the App Store): **bundle the Node runtime** (the ~127 MB arm64 `node` binary, copied into `Contents/Resources`) so the target needs no Node install; the Agent SDK's own child processes reuse it via `process.execPath`. **Ad-hoc signed, not notarised** (`codesign -s -`) — first launch needs right-click ▸ Open. **Whisper model not bundled** — the shipped app defaults to Apple SpeechAnalyzer (no model), with whisper optional via Application Support or `ADVISOR_WHISPER_MODEL`; bundling 1.5 GB for the non-default engine wasn't worth it.

The whisper dylibs (whisper + 5 ggml variants incl. Metal, whose shaders are embedded so no runtime `.metallib` is needed) are flattened into `Contents/Frameworks`; `@loader_path` resolves their inter-dependencies and `@executable_path/../Frameworks` resolves the main link. The script strips the absolute build-tree rpaths so the bundle is self-contained on any Mac. Verified: smoke test loads whisper from a copy in `/tmp` with dev rpaths gone; the bundled Node boots the bundled sidecar with no system Node on `PATH`. The sidecar still needs the user's Claude Code login on the target.

## Codex as an alternative provider (2026-06-13)

Each pipeline component — trigger classifier, research lanes, manual query lane — can independently run on **Claude** (Agent SDK) or **Codex** (`@openai/codex-sdk`), chosen in Preferences with a provider picker plus a provider-specific model picker (the choice remembers a model id per provider so switching back restores it). The sidecar abstracts both behind an `Agent` interface (`run`/`reset`/`interrupt`); `AgentSession` is the Claude impl, `CodexAgentSession` (`codex.ts`) the Codex one. Both are long-lived, FIFO, context-retaining sessions; `costUsd` is 0 for Codex (subscription, no per-token billing). **Caveat (measured 2026-06-13): Codex is unfit for the research/query lanes** — ~5–7× slower than Claude and non-streaming (card stays empty until done). Keep research/query on Claude; see the latency-investigation section below.

**Provider registry (plug-in shape).** `providers.ts` holds a `PROVIDERS` registry mapping id → `{ label, create(opts) }`, and `createAgent(provider, opts)` resolves through it (unknown id → Claude, forward-compatible with newer configs). Adding a provider is one registry entry + one `Agent` class on the sidecar, and one `AgentProvider.all` entry (id, label, model list) in the app's `Preferences.swift` — the provider/model pickers are data-driven from that array, no per-provider branches. The two lists are mirrored across the language boundary by hand (Swift can't import the TS registry). The per-provider sandbox/tooling impl is irreducible — each SDK differs.

Auth follows the same principle as Claude — **no API key**: the Codex SDK reuses the user's Codex CLI login (`~/.codex/auth.json`). The platform binary ships transitively via `@openai/codex-sdk` → `@openai/codex` → `@openai/codex-darwin-arm64` in `node_modules`, so packaging needs no global `codex` install. Codex has no system-prompt parameter, so Advisor's system prompt is prepended to the first turn of each thread; later turns inherit it from thread context.

**Sandbox — deliberately coarser than Claude's, documented not hidden.** Claude runs under a per-call `canUseTool` policy (path denylist for reads, action-pattern gate for MCP). The Codex SDK exposes no per-call hook, so `CodexAgentSession` maps to `sandboxMode: "read-only"` + `approvalPolicy: "never"` (no writes, edits, escalation, or network-mutating commands), with web search + network enabled only when the component has a `Web*` tool (research/query yes, classifier no). Residual gaps versus Claude: a read-only Codex *shell* command can still read sensitive dotfiles (`~/.ssh` etc.) — there is no path denylist — and Codex MCP servers come from `~/.codex/config.toml`, so they are not gated by `allowMcpActions`. Accept for a single-user local tool; revisit if Codex gains per-tool callbacks.

**Config migration.** `config.json` grew per-component `ProviderChoice` objects through three shapes: v1 flat `classifierModel`/`researchModel`; v2 `{provider, claudeModel, codexModel}`; v3 (current) `{provider, models: Record<provider,string>}` — a model map so new providers need no new field. Both sides normalise all three on read: sidecar `toChoice()`/`mergeConfig()` and a tolerant Swift `init(from:)` (v2→map handled inside `ProviderChoice`, v1 flat in `AdvisorConfig`; query inherits the old research model). The Swift decoder is deliberately tolerant of missing keys — synthesised `Decodable` would otherwise throw on an old file and the next Preferences save would silently wipe every setting.

## Latency investigation — progressive answers, warming, Codex unfit for research (2026-06-13)

First real-use complaint: 60 s+ from a spoken question to a useful card. Instrumented the whole pre-card path (per-stage + per-text-block latency logging in `agent.ts`/`main.ts`/`protocol.ts`, kept on permanently for ongoing tuning — each `[sidecar +Xs]` line is on one timeline). Findings, in order of impact:

- **Codex is unfit for the research/query lanes.** Measured the same question with research on Codex vs Claude/Opus: **Codex ~170 s, Claude ~25–34 s** — a 5–7× gap — and Codex emits nothing until the turn ends, so the card sits empty then pops. Claude streams text blocks as it writes. Keep research/query on Claude; Codex remains selectable (and fine for the classifier, whose output is a single JSON blob) but should not be the research/query backend. The earlier 170 s "agent is slow" symptom was almost entirely this misconfiguration, not the SDK.
- **Claude won't volunteer progressive output — it must be told.** Baseline (no instruction): Claude runs every tool then dumps one block; first text == final, ~24 s into the run. So the system prompt now mandates a **two-pass answer in one turn**: write a brief `From your notes:` preliminary from the local search *first*, then consult web/connectors and revise. With it, useful content reaches the card ~9 s into the run (~15 s earlier) for ~5 s more total. The prompt also **forbids narration** ("I'll check…") — the first block must be real content, or the early-content win is wasted on filler.
- **The local/web split was prototyped and rejected.** A throwaway spike fired a parallel local-only card (Read/Grep/Glob, no web) beside the web card. Local *started* faster (first text ~5 s) but *finished* slower (~38 s) — a heavy model doing many sequential `Read`s. The instructed single agent gives the same progressive feel with **one card and no second model**; the split's only real edge is parallelism, and gathering the local data (~15–20 s here) is the floor either way. Not worth the extra card/lane/model plumbing.
- **Cold-spawn warmed off the critical path.** The Agent SDK boots a CLI subprocess on the first `run()` of each session (~5–10 s; classifier Haiku measured cold 5.7–9.4 s). It was paid serially on the first question by both the classifier and the lead research lane. `session_start` now fires fire-and-forget warm-ups (`warmClassifier()` + a trivial run on `researchLanes[0]`) so the first real question skips both boots.

Remaining floor is STT finalisation (~8–12 s, app-side, separate) plus the unavoidable local-gather time. The ≤5 s aspiration in the latency budget above remains aspirational for agentic answers.

## Revisit as it grows

Echo suppression approach (M2 will tell); Haiku trigger cost at daily use; markdown vs SQLite once history is large; exposing an MCP server over past sessions (the hybrid from REQUIREMENTS).
