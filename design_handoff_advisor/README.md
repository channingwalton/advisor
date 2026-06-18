# Handoff: Advisor — Listening View Redesign

## Overview
**Advisor** is a personal macOS assistant that listens to conversations in real time
(meetings, calls, videos, in-person), transcribes them **locally / on-device**, and
**proactively injects cards** into the transcript that add background context, answer
questions, and fact-check claims as the conversation flows. The user can also ask the
assistant anything via a bottom Ask bar at any time.

This handoff covers a redesign of the **active "Listening" view** — the main screen
where the live transcript streams and cards are injected inline.

---

## About the Design Files
The files in this bundle are **design references created in HTML/CSS** — prototypes that
show the intended look, layout, and behavior. **They are not production code to port
line-for-line.** The task is to **recreate these designs natively in SwiftUI / AppKit**
using the app's existing patterns, then wire them to the real transcription + card
pipeline.

The design is the **inline model**: cards inject directly into the transcript stream
(`Advisor.dc.html`, with `Advisor (dark).dc.html` showing dark mode).

> These `.dc.html` files use a small runtime (`support.js`, included). To view them, open
> the HTML in a browser served from this folder, or just look at the PNGs in
> `screenshots/`. Treat the rendered result as the spec.

---

## Fidelity
**High-fidelity (hifi).** Colors, typography, spacing, radii, shadows, and interactions
are final. Recreate the UI to match. The one thing to confirm against the real app is
**dark mode** — this mock is light-mode only (see "Open Questions").

---

## Platform Notes (read first)
- This is a **real macOS window**. The traffic-light buttons and the title-bar background
  drawn in the HTML are **mockup-only** — in the Swift app they are provided by the OS
  (`NSWindow`). Do **not** redraw them. Build the toolbar + content as the window's
  content view.
- Window content width in the mock is **1040 pt**, height **864 pt**; the window is
  resizable in production — the design should reflow (transcript column stays centered,
  max readable width ~812 pt).
- Use SF Pro (the system font) throughout — `Font.system(...)`. Inline code uses SF Mono
  (`Font.system(..., design: .monospaced)`).
- Card bodies are essentially **Markdown** (bold, italic, inline `code`, bullet lists,
  links). Store card content as Markdown strings and render with `Text(AttributedString(markdown:))`
  / `Text(.init(markdown))` so you don't hand-build every run.

---

## Screens / Views

> **This pack covers two views.** The **Listening** view is specified below. The
> **Sessions (history)** view has its own spec — see **`SESSIONS.md`** (design file
> `Advisor Sessions.dc.html`, render `screenshots/sessions.png`). They are two top-level
> destinations of the same window, linked by the **Sessions** button (title bar) and
> **New session**.

### View: Listening (main window)
**Purpose:** Watch the live transcript and the cards the assistant injects; ask follow-ups.

**Vertical layout (top → bottom):**
1. **Title bar** (OS-provided) — app title "Advisor" + a live status pill
   (`● Listening · 18:24`, red pulsing dot). Status pill can live in the toolbar's center
   or as an `NSToolbar` title accessory.
2. **Toolbar** — 60 pt tall, hairline bottom border.
3. **Transcript scroll area** — flexible height, vertical scroll. Centered column,
   max-width 812 pt, padding `26 / 28 / 40`.
4. **Ask bar** — pinned to bottom, ~115 pt tall including suggestion chips.

#### Toolbar (left → right)
- **Record cluster** (pill, radius 11, white→`#FBFBFD` gradient, 0.5px border
  `rgba(255,69,58,0.28)`):
  - Animated **waveform** — 5 vertical bars, `#FF453A`, width 2.5, height 16,
    each `scaleY` oscillates 0.35↔1 over 0.9s, staggered 0.15s.
  - **Timer** `18:24` — 12.5 pt, weight 600, color `#D8362D`, tabular figures.
  - **Pause** button (two bars) — 30×30, radius 8, white, hairline border.
  - **Stop** button — 30×30, radius 8, solid `#FF453A`, white rounded square glyph.
- **Audio source** button — 34 pt tall, radius 9, white. Mic glyph + two lines:
  `Studio Display Mic` (12 pt / 600) over `+ system audio` (10 pt / `#9596A0`), with an
  up/down chevron. Opens a source picker.
- *(pushed right)*
- **Focus chip** — radius 9, bg `#EEF1FB`, border `rgba(58,92,224,0.18)`. Uppercase
  label `FOCUS` (10.5 pt / 700 / `#3A5CE0`) + value text (`Effect systems · research talk`,
  12 pt / `#3B4254`) + `Edit`. This replaces the old empty "session prompt" textarea — it
  is the editable session prompt, collapsed to a chip.
- **Auto cards** toggle — label (12 pt) + a switch (use native `Toggle`/`NSSwitch`;
  on-state tint `#3A5CE0`). When off, no cards auto-inject.
- **Float** button — 34×34, radius 9, white. Toggles a small always-on-top overlay
  window (not designed here).

#### Transcript area
- **Day divider** — centered, 10.5 pt, `#AEAFB8`: `Today · 6:22 PM · on-device transcription`.
- **Transcript paragraphs** — plain flowing text, 14.5 pt, line-height 1.68, color
  `#3A3B44`, ~18 pt bottom spacing. **No speaker labels / avatars / timestamps** (the app
  does not diarize — see Open Questions). Key terms the assistant is about to expand on are
  highlighted with a `<mark>`: bg `#EAE6FB`, text `#6044C0`, radius 3.
- **Interim (live) line** — the not-yet-finalized text, color `#80818B`, ending in a
  blinking caret (7×16 pt bar, `#3A5CE0`, opacity blink 1s).
- **Cards** — injected between paragraphs, full-width within the column. See Card Types.

#### Ask bar
- **Suggestion chips** row — pill chips (11.5 pt, white, hairline border, radius 14):
  e.g. `Summarize the last 5 minutes`, `Which of these is production-ready?`,
  `Draft a follow-up question`. Tapping one fills the input / sends.
- **Input** — 44 pt tall, radius 12, white, hairline border. Leading `✦` glyph in accent,
  placeholder `Ask anything about this conversation — or beyond it…`, trailing `⌘ ↵` key hint.
- **Ask** button — 44 pt, radius 12, solid `#3A5CE0`, white text 14 pt / 600.

---

## Card Types
All cards share a base: white surface, radius **14**, 0.5px border `rgba(0,0,0,0.09)`,
card shadow `0 5px 18px -8px rgba(20,22,40,0.18), 0 1px 2px rgba(0,0,0,0.04)`. Header row
(type pill + title + status + actions), body (Markdown), footer (trigger quote + sources),
and an optional follow-up input.

Every card header has, pushed to the right:
- **Collapse/Expand** chevron button (26×26, radius 7, transparent, hover bg `#F1F1F5`).
- **Dismiss** `×` button (same styling). Removing a card removes it from the stream.

### 1. CONTEXT (background / definitions) — accent **violet `#6044C0`**
- Type pill: `CONTEXT`, text `#6044C0`, bg `#EEE9FB`, 5 pt dot, 10 pt / 700 / uppercase /
  letter-spacing 0.5.
- Title: 15 pt / 600–650 / `#2A2B33`.
- Optional **"Researching"** status: spinner (11 pt ring, `#9596A0` head on `#DCDCE3`
  track, rotate 0.7s) + label `#9596A0`. Shown while the card is still resolving sources.
- Body: Markdown. Inline `code` style: SF Mono 11.5 pt, bg `#F1F0F6`, text `#6E54B8`,
  radius 4, padding `1×5`. Bullet markers: 5 pt dot, `#C3B8E8`.
- Footer: `↳ "trigger phrase"` (11 pt italic `#8A8B95`) + right-aligned source links
  (11 pt `#3A5CE0`).
- Follow-up input: 34 pt, bg `#F7F7FA`, placeholder `Ask a follow-up about …` + neutral
  `Send` button.

### 2. ANSWER (reply to a user question) — accent **blue `#3A5CE0`**
- Border tinted `rgba(58,92,224,0.22)`, shadow tinted blue.
- Type pill: `ANSWER` (blue). Header subtitle: `replying to your question`.
- Title: the headline answer, 14.5 pt / 650 / `#2A2B33`.
- Body Markdown; inline code uses blue tint (bg `#EAEEFB`, text `#3A5CE0`).
- Footer: `Grounded in the live conversation` + source links.
- Follow-up input with a **solid blue** `Send` button.

### 3. FACT-CHECK — verdict-colored
- Verdicts:
  - **VERIFIED** — green `#2F8D5B`, pill bg `#E6F4EC`, 12 pt badge with `✓`.
  - **NEEDS CONTEXT** — amber `#A06A12` (badge `#C79018`), pill bg `#FAF0DB`, `!`.
  - (Add **MISLEADING/FALSE** — red — same shape if needed.)
- Often shown **collapsed by default**: a single header row with verdict badge + a
  one-line claim (truncated) + expand/dismiss. Expanding reveals the explanation Markdown +
  footer (trigger quote + source link).

### Collapsed card pattern (important)
Cards can grow long and bury the live transcript, so **non-critical cards collapse to a
single row** (type/verdict pill + title + optional one-line summary + expand/dismiss
chevrons). Expanding shows the full body/footer/follow-up. Default states in the mock:
CONTEXT (OCaml) and ANSWER are expanded; FACT-CHECK (Perceus) and the second CONTEXT
(Granule) are collapsed.

---

## Interactions & Behavior
- **Record controls:** Pause pauses capture (keeps session); Stop ends the session.
  Toolbar reflects state (idle → no waveform/timer; listening → animated waveform, red
  pulsing status dot, running timer).
- **Waveform:** continuous loop; in production, drive bar heights from the live input
  level (RMS) for real feedback instead of a fixed loop.
- **Card lifecycle:** `researching` (spinner) → `ready` (sources resolved). New cards
  animate in (fade + 8 pt rise, ~0.4s). Expand/collapse animates height. Dismiss removes.
- **Highlights:** the `<mark>` on a transcript term corresponds to the card triggered by
  it; consider linking them (hover/tap to scroll to the card).
- **Ask bar:** ⌘↵ submits; a submitted question injects an ANSWER card inline.
- **Hover states:** all buttons lighten background (`#F1F1F5`–`#F6F6FA`) on hover; the
  blue Ask/Send buttons darken to `#3350CF`.

---

## State Management
Suggested model (SwiftUI `@Observable` / `ObservableObject`):

```
enum RecordingState { case idle, listening, paused }

struct TranscriptSegment: Identifiable {
    let id: UUID
    var text: String          // may contain marked terms
    var isInterim: Bool       // true = not yet finalized (gray + caret)
}

enum CardKind { case context, answer, factCheck(Verdict) }
enum Verdict  { case verified, needsContext, misleading }
enum CardStatus { case researching, ready }

struct Card: Identifiable {
    let id: UUID
    var kind: CardKind
    var title: String
    var bodyMarkdown: String
    var triggerQuote: String?     // the transcript phrase that spawned it
    var sources: [Source]         // label + URL
    var status: CardStatus
    var isExpanded: Bool
    var anchorSegmentID: UUID?    // where it injects in the stream
}

@Observable final class SessionModel {
    var recording: RecordingState = .idle
    var elapsed: TimeInterval = 0
    var autoCards = true
    var focusPrompt = "Effect systems · research talk"
    var audioSource = "Studio Display Mic + system audio"
    var segments: [TranscriptSegment] = []
    var cards: [Card] = []         // interleaved with segments by anchor
    func ask(_ q: String) { /* inject ANSWER card */ }
    func toggleCard(_ id: UUID) { /* expand/collapse */ }
    func dismissCard(_ id: UUID) { /* remove */ }
}
```

**Rendering the stream:** build one ordered list interleaving `segments` and `cards` (by
anchor / timestamp) and render in a `ScrollView { LazyVStack(alignment: .leading) }`.
Auto-scroll to bottom while listening unless the user has scrolled up.

---

## Design Tokens

### Color
| Token | Hex |
|-------|-----|
| Window / surface bg | `#FBFBFD` |
| Title-bar gradient | `#FDFDFF` → `#F4F4F8` |
| Desktop bg (mock only) | `#ECECF1` → `#E2E2E8` |
| Hairline border | `rgba(0,0,0,0.07–0.14)` (0.5 pt) |
| Text — strong | `#2A2B33` / `#34353D` |
| Text — body | `#3A3B44` / `#44454F` |
| Text — secondary | `#5E5F69` / `#8A8B95` / `#9596A0` |
| Text — muted | `#AEAFB8` / `#B0B1BA` |
| Accent (blue) | `#3A5CE0` · hover `#3350CF` · tints `#E7ECFD` `#EEF1FB` `#F5F7FE` |
| Record red | `#FF453A` / `#D8362D` |
| Context violet | `#6044C0` · tints `#EEE9FB` `#F1F0F6` · code `#6E54B8` |
| Fact-check green | `#2F8D5B` · tint `#E6F4EC` |
| Fact-check amber | `#A06A12` / `#C79018` · tint `#FAF0DB` |
| Term highlight | bg `#EAE6FB` · text `#6044C0` |
| Live / on-device green | `#54A85E` |
| Traffic lights (mock) | `#FF5F57` `#FEBC2E` `#28C840` |

### Type scale (SF Pro)
| Use | Size / weight / line-height |
|-----|-----|
| App title | 13.5 / 600 |
| Status, toolbar labels | 12 / 500–600 |
| Uppercase micro-labels (FOCUS, type pills) | 10–10.5 / 700 / +0.4–0.5 tracking |
| Transcript body | 14.5 / regular / 1.68 |
| Card title | 14.5–15 / 600–650 |
| Card body | 13.5 / regular / 1.58 |
| Inline code | 11.5 / SF Mono |
| Footer / trigger quote | 11 / italic |
| Ask input | 14 |

### Spacing / radius / shadow
| Token | Value |
|-------|-------|
| Window radius | 13 |
| Card radius | 14 |
| Button radius | 7–9 |
| Pill radius | 6 (labels) / 14 (chips) |
| Input radius | 12 |
| Toolbar height | 60 · Title bar | 52 |
| Content column max-width | 812 · padding 26/28/40 |
| Card shadow | `0 5px 18px -8px rgba(20,22,40,0.18), 0 1px 2px rgba(0,0,0,0.04)` |
| Collapsed-card shadow | `0 3px 12px -8px rgba(20,22,40,0.14)` |
| Window shadow (mock) | `0 28px 70px -18px rgba(20,22,40,0.42)` |

### Animation
| Element | Spec |
|---------|------|
| Waveform bars | `scaleY` 0.35↔1, 0.9s ease-in-out, loop, 0.15s stagger |
| Status dot pulse | expanding ring, 1.8s loop |
| Researching spinner | 360° rotate, 0.7s linear, loop |
| Live caret | opacity blink, 1s steps |
| Card enter | fade + translateY 8→0, ~0.4s ease |

---

## Dark Mode
The app follows the **system appearance**, so every color must be defined as a
**semantic / dynamic color** (Asset Catalog color set with Any + Dark, or
`NSColor(name:dynamicProvider:)`) — never a hardcoded hex. The light values are in
“Design Tokens” above; map each to the dark value below. Surfaces get *lighter* with
elevation in dark mode (window < card), the inverse of light mode.

| Semantic token | Light | Dark |
|----------------|-------|------|
| `surface/window` | `#FBFBFD` | `#1D1D20` |
| `surface/titlebar` | `#FDFDFF`→`#F4F4F8` | `#2A2A2E`→`#232327` |
| `surface/card` | `#FFFFFF` | `#2B2B30` |
| `surface/card-inset` (follow-up input) | `#F7F7FA` | `#202024` |
| `border/hairline` | `rgba(0,0,0,0.07–0.14)` | `rgba(255,255,255,0.10–0.16)` |
| `text/strong` | `#2A2B33` | `#F2F2F6` |
| `text/body` | `#3A3B44` / `#44454F` | `#DCDDE3` / `#C6C7CF` |
| `text/secondary` | `#5E5F69` / `#8A8B95` | `#A6A7B0` / `#8C8D97` |
| `text/muted` | `#AEAFB8` | `#6F7079` |
| `accent` | `#3A5CE0` · hover `#3350CF` | `#6E8BFF` · hover `#829BFF` |
| `accent/tint` (chips, focus, answer bg) | `#E7ECFD` / `#EEF1FB` | `rgba(110,139,255,0.16)` |
| `record/red` | `#FF453A` / text `#D8362D` | `#FF5F55` / text `#FF8077` |
| `context/violet` | `#6044C0` | `#B9A4FF` |
| `context/tint` | `#EEE9FB` | `rgba(185,164,255,0.16)` |
| `context/code` | bg `#F1F0F6` text `#6E54B8` | bg `rgba(185,164,255,0.14)` text `#CCBEFF` |
| `factcheck/green` | `#2F8D5B` | `#46D389` |
| `factcheck/green-tint` | `#E6F4EC` | `rgba(70,211,137,0.16)` |
| `factcheck/amber` | `#A06A12` / `#C79018` | `#ECB845` |
| `factcheck/amber-tint` | `#FAF0DB` | `rgba(236,184,69,0.16)` |
| `term-highlight` | bg `#EAE6FB` text `#6044C0` | bg `rgba(185,164,255,0.22)` text `#CCBEFF` |
| `live/green` | `#54A85E` | `#5FD07A` |

**Notes**
- **White text on colored fills stays white** in both modes (e.g. the Ask/Stop button
  glyphs, badge checkmarks) — do not invert these.
- **Shadows** read as near-invisible in dark mode; lean on the elevated card surface +
  hairline border for separation instead of increasing shadow opacity. Keep ambient
  shadow subtle (`rgba(0,0,0,0.4)` y-blur only) or drop it on cards in dark.
- **Term highlights & inline code** use translucent tints (rgba over the surface) so they
  sit correctly on either background — avoid solid pastel fills in dark.
- Prefer Apple’s built-ins where they fit: `NSColor.windowBackgroundColor`,
  `.controlBackgroundColor`, `.labelColor`/`.secondaryLabelColor`/`.tertiaryLabelColor`,
  `.controlAccentColor` (respects the user’s system accent) — use the custom hex sets only
  for the brand violet/green/amber/red semantics above.

> Both **light and dark** visual mocks are included — see `screenshots/` and
> `Advisor (dark).dc.html`.

## Assets
No bitmap assets. All glyphs (mic, pause, stop, chevrons, float, waveform, ✦) are drawn
with CSS in the mock — in Swift, replace with **SF Symbols** where possible:
`mic.fill`, `pause.fill`, `stop.fill`, `chevron.up.chevron.down`,
`macwindow.on.rectangle` (Float), `sparkle` (✦ Ask), `xmark`, `chevron.down`, etc.

---

## Files
- `Advisor.dc.html` — primary inline-card listening view (build this).
- `Advisor Sessions.dc.html` — the Sessions / history view (spec in `SESSIONS.md`).
- `SESSIONS.md` — spec for the Sessions view (read alongside this README).
- `support.js` — runtime needed to render the `.dc.html` files in a browser.
- `Advisor (dark).dc.html` — the primary view in **dark mode** (system-appearance reference).
- `screenshots/listening-inline.png` — render of the primary design (light).
- `screenshots/listening-inline-dark.png` — render of the primary design (dark).

---

## Open Questions to confirm before building
1. **Dark mode** — this mock is light only. The app almost certainly needs dark mode;
   define dark tokens (or use semantic `NSColor`s) before implementing.
2. **Diarization** — this design assumes **no speaker labels** (flowing paragraphs). If
   the app actually separates speakers, re-introduce lightweight speaker attribution.
3. **Resize behavior** — confirm min/ideal window size and how the column behaves when
   the window is very wide or narrow.
