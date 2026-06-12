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

**SidecarManager.** Spawns the Node sidecar, supervises (restart with backoff, max 3; replay last 60 s of utterances on restart so context survives). Transport: newline-delimited JSON over stdin/stdout. Chosen over WebSocket: no port management, lifecycle tied to parent, trivially debuggable. Logs on stderr.

**OverlayUI.** Non-activating `NSPanel` (`.floating`, `.nonactivatingPanel`) hosting SwiftUI: vertical card feed (newest top), collapsible live transcript drawer, query box, listening indicator + cost ticker. Menu-bar item: start/stop listening, open session history. Panel never takes key focus except when the query box is clicked.

**SessionStore.** One markdown file per session in `~/Library/Application Support/Advisor/sessions/YYYY-MM-DD-HHmm.md`: YAML frontmatter (start/end, cost), transcript section, cards section (type, body, sources). Written incrementally; transcripts only, no audio (decided). Vault is never written.

### TS sidecar (Claude Agent SDK)

**TriggerDetector.** Maintains rolling transcript window (~2 min). On each utterance (debounced 1.5 s of silence-or-topic-shift), one Haiku call classifies: `question | entity | claim | none` + extracted subject. Dedup: don't re-trigger on a subject already carded in the last 10 min.

**ResearchAgent.** Per trigger, an Agent SDK query with budget caps (max turns ~6, streaming). Tools: web search; read-only filesystem MCP rooted at `~/Documents/Notes` and configured repo dirs; Atlassian + Slack MCPs. System prompt per trigger type (answer / context / fact-check). Fact-check answers must cite or return "couldn't verify" — never guess. Emits card immediately as placeholder, then streams body updates.

**QueryHandler.** F14 on-demand queries: same agent, full current-session transcript as context, results stream to a pinned card.

## IPC contract (NDJSON, one object per line)

Swift → sidecar:

```json
{"type":"session_start","sessionId":"...","ts":...}
{"type":"utterance","id":"u123","source":"them","text":"...","t0":...,"t1":...}
{"type":"query","id":"q7","text":"..."}
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

Sidecar crash → supervisor restarts, replays window, UI shows transient "reconnecting". STT stall → watchdog restarts decode queue. LLM/tool failure → card flips to `failed` with reason; never silent. Anthropic key missing/invalid → blocking banner at session start, not mid-conversation.

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
- **M5: ✅ 2026-06-13.** Persistent research/query sessions (per-lane transcript-delta cursors; follow-up questions resolve referents from session memory). Cost reporting via per-task `total_cost_usd` deltas → ticker in toolbar. Session markdown files in `~/Library/Application Support/Advisor/sessions/` (debounced rewrite; late cards included). "Pin" toggle (floating window, all spaces) instead of a full NSPanel overlay — revisit if focus-stealing annoys. "Sessions" button opens the folder in lieu of an in-app history view.

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

## Revisit as it grows

Echo suppression approach (M2 will tell); Haiku trigger cost at daily use; markdown vs SQLite once history is large; exposing an MCP server over past sessions (the hybrid from REQUIREMENTS).
