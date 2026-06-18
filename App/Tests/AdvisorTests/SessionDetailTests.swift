import Foundation
import Testing

@testable import Advisor

private let note = """
---
started: 2026-06-18T17:00:00Z
ended: 2026-06-18T17:34:00Z
context: Effect systems research talk
---

# Transcript

- 17:00:00 OCaml is adopting effect systems.

> **CONTEXT · OCaml effect systems**
>
> handlers added in OCaml 5.0, untyped by design
>
> _↳ "OCaml is adopting effect systems"_

- 17:00:05 More discussion follows.

# Follow-ups

> **Q · Which is production-ready?**
>
> OCaml 5 ships effects.
>
> _Asked 18:31 · 2026-06-18_
"""

@Test func contextBecomesTitle() {
    let d = SessionDetail.parse(contents: note, fallbackTitle: "fallback")
    #expect(d.title == "Effect systems research talk")
    #expect(d.durationMinutes == 34)
    #expect(d.gist == "OCaml is adopting effect systems.")
}

@Test func missingContextFallsBackToTitle() {
    let bare = "---\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n\n- 17:00:00 hi"
    let d = SessionDetail.parse(contents: bare, fallbackTitle: "Thu 18 Jun, 5:00 PM")
    #expect(d.title == "Thu 18 Jun, 5:00 PM")
}

@Test func surfacedCardsParsedAndQuestionsSplitOut() {
    let d = SessionDetail.parse(contents: note, fallbackTitle: "x")
    #expect(d.cards == [
        SurfacedCard(
            label: "CONTEXT", title: "OCaml effect systems",
            snippet: "handlers added in OCaml 5.0, untyped by design"),
    ])
    #expect(d.questions == [
        AskedQuestion(question: "Which is production-ready?", askedAt: "18:31"),
    ])
}

@Test func frontmatterParsesContext() {
    #expect(SessionArchive.frontmatter(note)["context"] == "Effect systems research talk")
}

@Test func inlineWritesContextToFrontmatter() {
    let md = SessionMarkdown.inline(
        utterances: [], cards: [], started: Date(timeIntervalSince1970: 0), ended: nil,
        context: "Q3 board review\nsecond line")
    // Multi-line context collapses to one frontmatter scalar.
    #expect(md.contains("context: Q3 board review second line\n"))
}
