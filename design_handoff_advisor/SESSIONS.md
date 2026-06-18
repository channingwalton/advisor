# Handoff: Advisor — Sessions (History) View

Companion to `README.md` (the Listening view). Same app, same design system, same
platform notes — **read `README.md` first** for tokens, fonts, and platform conventions;
this doc only covers what's specific to the Sessions view.

## Overview
**Sessions** is where the user reviews **past conversations**. Every time Advisor listens
to a meeting/call/lecture, it saves a **session**: the transcript, the cards it surfaced,
any questions the user asked, detected action items, and metadata (time, duration, audio
source, people). This screen lets the user browse, search, and reopen them.

The design file is `Advisor Sessions.dc.html` (render: `screenshots/sessions.png`). As with
the rest of the pack, it's an **HTML reference to recreate natively in SwiftUI/AppKit** —
not code to port.

## Where it lives
Reached from the **Sessions** button in the Listening view's title bar. Treat Listening
and Sessions as two top-level destinations of the same window (a `NavigationSplitView`, or
your existing navigation). The **New session** button (top-right, red dot) starts a new
recording and returns to the Listening view.

---

## Layout — Master/Detail
A classic two-column macOS layout. In SwiftUI this is a **`NavigationSplitView`** with a
sidebar (session list) + detail.

```
┌─ Title bar ─────────────────────────────────────────────┐
│  ●●●        Advisor · Sessions          [● New session]  │
├──────────────────┬──────────────────────────────────────┤
│  Search          │  DETAIL (selected session)           │
│  [All][★][Week]  │   badge · Title · meta · chips       │
│  ───────────     │   Summary card                       │
│  TODAY           │   Cards surfaced ›                    │
│   • Session row  │   You asked / Action items           │
│  YESTERDAY       │   Transcript excerpt                 │
│   • Session row  │                                      │
│  EARLIER…        │                                      │
└──────────────────┴──────────────────────────────────────┘
```

- **Sidebar width:** 350 pt fixed (`#F7F7FA`), hairline right border. Detail fills the rest
  (`#FBFBFD`), scrolls independently.
- Selecting a row swaps the detail pane. Default selection = most recent session.

### Sidebar
- **Search field** (34 pt, white, radius 9) — placeholder `Search sessions, people, topics…`.
  Searches title, people, and topics.
- **Filter chips** — `All` (selected = solid blue `#3A5CE0`, white text), `Starred`,
  `This week` (unselected = white, hairline border). Right-aligned **sort** control
  (`Recent ▾`).
- **Section headers** — `TODAY`, `YESTERDAY`, `EARLIER THIS WEEK` (also `THIS MONTH`,
  `EARLIER` as the list grows). 10.5 pt / 700 / uppercase / `#AEAFB8`. Group by relative
  date.
- **Session row** (the key list item):
  - **Topic dot** — a per-session color (category-derived; see Categories).
  - **Title** — 13.5 pt / 650 / `#2A2B33`, truncates.
  - **Time** — right-aligned, 11 pt / `#AEAFB8` (e.g. `6:22 PM`, or `Mon` when older).
  - **Gist** — one-line subtitle, 11.5 pt / `#8A8B95`, truncates.
  - **Meta row** — duration · **card count** (colored to the category) · people count;
    optional trailing **★** if starred.
  - **Selected state:** white card fill, soft shadow, `inset 0 0 0 1px rgba(58,92,224,0.22)`,
    and a 3 pt blue accent bar down the left edge. (Implement as the row's
    selected-background; the accent bar is a leading rule.)

### Detail pane
Top → bottom, 26/30 padding:
1. **Header row:**
   - **Category badge** — uppercase pill, colored per category (see table).
   - **Title** — 23 pt / 700 / `#26272F`.
   - **Meta line** — `date · time-range`, `duration` (tabular), `audio source` **or**
     participant names, separated by 3 pt dots.
   - **Actions** (right): **Resume** (solid blue, play glyph — reopens/continues the
     session), **★** star toggle, **⋯** overflow (Export, Rename, Delete, Reveal
     transcript…).
2. **Topic chips** — the entities/topics Advisor tracked, tinted to the category
   (`OCaml 5`, `Koka`, `NRR 118%`…). `white-space: nowrap` each.
3. **Summary card** — white, radius 13, hairline, soft shadow. Header `✦ SUMMARY`
   (uppercase micro-label). Body is **Markdown** (bold/italic), ≈3–4 sentences — Advisor's
   recap of the session.
4. **Cards surfaced** — section label + count + `View all`. Then **compact card rows**
   (one line each): type/verdict pill + short title + dimmed one-line detail + chevron `›`.
   Pills reuse the Listening view's card colors (CONTEXT violet, ANSWER blue, VERIFIED
   green, CHECK amber, COMPANY teal). Tapping a row opens that card / jumps to it in the
   transcript.
5. **Per-category extra section** (optional, depends on session):
   - **You asked** — list of questions the user asked during the session, each with a `Y`
     avatar + “Answered inline · HH:MM”.
   - **Action items** — checkbox rows with optional due date (red when due soon). Advisor
     auto-detects these (e.g. from a customer call).
6. **Transcript excerpt** — muted panel (`#F7F7FA`) with a short quote (terms highlighted
   via `<mark>`, same highlight tokens as Listening) + `+ N more minutes of transcript` and
   an `Open full transcript` link.

---

## Categories
Each session has a **category** that drives its badge, topic dot, chip tint, and card-count
color. Suggested set (extend as needed):

| Category | Accent | Badge / dot |
|----------|--------|-------------|
| Research seminar / Lecture | violet `#6044C0` (lecture variant uses blue `#3A5CE0`) | `RESEARCH SEMINAR`, `LECTURE` |
| Internal meeting | green `#2F8D5B` | `INTERNAL MEETING` |
| Customer call | orange `#D8862E` | `CUSTOMER CALL` |

Store the category on the session; derive all four color usages from it so a new category
is one entry.

---

## Data model (extends README's model)
```swift
struct Session: Identifiable {
    let id: UUID
    var title: String
    var category: SessionCategory          // drives color/badge
    var gist: String                       // one-line subtitle
    var startedAt: Date
    var duration: TimeInterval
    var audioSource: String                // e.g. "Studio Display Mic + system audio"
    var participants: [String]             // [] for lecture/solo capture
    var topics: [String]                   // chip labels
    var summaryMarkdown: String
    var cards: [Card]                      // Card from README
    var askedQuestions: [AskedQuestion]    // q + answeredAt
    var actionItems: [ActionItem]          // text + dueDate? + done
    var transcript: [TranscriptSegment]    // TranscriptSegment from README
    var isStarred: Bool
}

enum SessionCategory { case researchSeminar, lecture, internalMeeting, customerCall /* … */ }
struct AskedQuestion: Identifiable { let id: UUID; var text: String; var answeredAt: Date }
struct ActionItem: Identifiable { let id: UUID; var text: String; var dueDate: Date?; var done: Bool }

@Observable final class SessionsStore {
    var sessions: [Session] = []
    var query: String = ""
    var filter: SessionFilter = .all       // all / starred / thisWeek
    var selectedID: Session.ID?
    var grouped: [(label: String, sessions: [Session])] { /* group filtered+sorted by relative date */ }
}
```
- **Sidebar** = `List(selection:)` over `store.grouped`, `Section`s per date label.
- **Detail** = a `ScrollView` rendering the selected `Session` (fall back to an empty state
  when `selectedID == nil`).
- **Resume** continues an existing `SessionModel` from this session; **New session** starts
  a fresh recording (Listening view).
- Persist sessions locally (on-device, consistent with the product's privacy stance) — Core
  Data / SwiftData / files, per the app's existing storage.

---

## Behaviors to implement
- Live **search** filters across title/people/topics; **filter chips** and **sort** narrow
  the list; selecting a row updates the detail pane.
- **Star** toggles from both the row and the detail header.
- **⋯ overflow:** Export (Markdown/PDF), Rename, Delete, Reveal full transcript.
- **Compact card row** → opens the full card; **Open full transcript** → full transcript
  view (not designed here — a future screen).
- **Empty states:** no sessions yet (prompt to start one); no search results.
- **Dark mode:** use the semantic tokens from `README.md`'s Dark Mode table — same surfaces,
  borders, and accents apply here (sidebar = the elevated/secondary surface, detail = base).

---

## Files
- `Advisor Sessions.dc.html` — the Sessions view design (recreate natively).
- `screenshots/sessions.png` — render of the design.
