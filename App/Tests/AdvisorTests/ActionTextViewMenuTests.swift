import AppKit
import Testing

@testable import Advisor

// The right-click menu's correction items act on the highlighted span. A
// paragraph shows its lines joined by spaces, and a span across a join lies in
// neither line, so it can't be corrected (issue #92): the menu says so instead
// of offering a correction that would fail or, for "Replace all", rewrite other
// copies and leave the selected one as it was.

@MainActor
private func menu(selecting range: NSRange, in lines: [String]) throws -> NSMenu {
    let tv = ActionTextView(frame: .zero)
    SelectableTranscriptText(
        text: lines.joined(separator: " "), toolTip: "", actions: [], onAction: { _, _ in },
        onCorrect: { _ in }, lines: lines
    ).apply(to: tv)
    tv.setSelectedRange(range)
    let event = try #require(
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    return try #require(tv.menu(for: event))
}

@MainActor
private func menu(selecting selection: String, in lines: [String]) throws -> NSMenu {
    let range = (lines.joined(separator: " ") as NSString).range(of: selection)
    #expect(range.location != NSNotFound)
    return try menu(selecting: range, in: lines)
}

@MainActor
@Test func menuOffersBothCorrectionsForASpanWithinOneLine() throws {
    let items = try menu(selecting: "is a dog", in: ["this is", "a cat, this is a dog"]).items
    let correct = try #require(items.first { $0.title.hasPrefix("Correct “is a dog”") })
    let all = try #require(items.first { $0.title.hasPrefix("Replace all “is a dog”") })
    #expect(correct.isEnabled && all.isEnabled)
}

@MainActor
@Test func menuRefusesASpanAcrossAJoin() throws {
    let items = try menu(selecting: "is a cat", in: ["this is", "a cat, this is a dog"]).items
    #expect(!items.contains { $0.title.hasPrefix("Correct “") || $0.title.hasPrefix("Replace all “") })
    let refusal = try #require(items.first { $0.title.contains("spans two lines") })
    #expect(!refusal.isEnabled)
    #expect(refusal.title == "Can't correct “is a cat” — it spans two lines")
}

@MainActor
@Test func menuRefusesASpanOverlappingAnEarlierMatchWithItsOwnReason() throws {
    // Selecting the second "aa" of "aaa": non-overlapping counting puts it at
    // index 1, and there is no second match — within one line, not a straddle.
    let items = try menu(selecting: NSRange(location: 1, length: 2), in: ["aaa"]).items
    #expect(!items.contains { $0.title.hasPrefix("Correct “") || $0.title.contains("spans two lines") })
    let refusal = try #require(items.first { $0.title.hasPrefix("Can't correct “aa”") })
    #expect(!refusal.isEnabled)
    #expect(refusal.title == "Can't correct “aa” — it overlaps an earlier “aa”")
    // "Replace all" takes no occurrence index and rewrites the highlight with the
    // rest ("aaa" → "ba" for aa → b), so it is still offered.
    #expect(items.contains { $0.title == "Replace all “aa”…" && $0.isEnabled })
}

@MainActor
@Test func menuRefusesASpanOverlappingAnEarlierMatchWhenALaterMatchExists() throws {
    // The middle "the the" of "the the the the" (UTF-16 4..<11): non-overlapping
    // matches are at 0 and 8, so its index is 1 and that match is the trailing
    // one. Offering the correction would rewrite the trailing copy instead.
    let items = try menu(selecting: NSRange(location: 4, length: 7), in: ["the the the the"]).items
    #expect(!items.contains { $0.title.hasPrefix("Correct “") })
    #expect(items.contains { $0.title == "Can't correct “the the” — it overlaps an earlier “the the”" && !$0.isEnabled })
    #expect(items.contains { $0.title == "Replace all “the the”…" && $0.isEnabled })
    // The trailing copy itself is fine.
    let trailing = try menu(selecting: NSRange(location: 8, length: 7), in: ["the the the the"]).items
    #expect(trailing.contains { $0.title.hasPrefix("Correct “the the”") && $0.isEnabled })
}

@MainActor
@Test func menuRefusesASpanWhoseTrimmedTextCrossesAJoin() throws {
    // The selection is trimmed before it is matched, so surrounding spaces
    // don't change the verdict.
    let items = try menu(selecting: " is a cat", in: ["this is", "a cat"]).items
    #expect(items.contains { $0.title.contains("spans two lines") })
    // A straddle offers neither scope: "Replace all" would leave this copy as it
    // is and report success (DESIGN.md, issue #92).
    #expect(!items.contains { $0.title.hasPrefix("Replace all “") })
}

@MainActor
@Test func menuTrimsAnyWhitespaceBeforeTheHighlightedText() throws {
    // A no-break space and a CRLF are trimmed like a space, so the trimmed text's
    // start is found where it is, not taken as the highlight's start — which
    // would read as an overlap with an earlier match.
    for pad in ["\u{00A0}", "\r\n", "\t "] {
        let line = "the\(pad)cat sat"
        let items = try menu(selecting: NSRange(location: 3, length: (pad as NSString).length + 3), in: [line]).items
        // The label is the raw highlight, whitespace and all; the prompt trims it.
        #expect(items.contains { $0.title.hasPrefix("Correct “") && $0.isEnabled }, "pad \(pad.debugDescription)")
        #expect(!items.contains { $0.title.contains("overlaps an earlier") }, "pad \(pad.debugDescription)")
    }
}

@MainActor
@Test func menuOffersCorrectionsWithNoLinesGivenAsASingleLine() throws {
    // With no `lines` the text is one line (`lines ?? [text]`), so a highlight
    // within it is correctable.
    let tv = ActionTextView(frame: .zero)
    SelectableTranscriptText(text: "a cat sat", toolTip: "", actions: [], onAction: { _, _ in }, onCorrect: { _ in })
        .apply(to: tv)
    tv.setSelectedRange(NSRange(location: 2, length: 3))
    let event = try #require(
        NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let items = try #require(tv.menu(for: event)).items
    #expect(items.contains { $0.title == "Correct “cat”…" && $0.isEnabled })
    #expect(items.contains { $0.title == "Replace all “cat”…" && $0.isEnabled })
}
