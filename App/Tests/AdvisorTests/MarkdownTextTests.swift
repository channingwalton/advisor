import AppKit
import Testing

@testable import Advisor

/// The shape research cards actually take: a lead line bound to the list under
/// it, nested bullets indented two spaces, ordered lists, and plain paragraphs.
private let card = """
Intro paragraph that
wraps softly.

**What it is** ([topic note](https://example.com/topic))
- **The idea:** digital workers.
- **Roles:**
  - Delivery: ETL.
  - Coordinator: plans.
- **How it learns:** kept apart.

**Blockers:** none recorded.

**Progress**

**Best questions** (from your prep note)
1. Is any of it built?
2. Who is it for?

# Heading

---
"""

private typealias Line = MarkdownText.Line

@Test func cardLinesClassifyLeadsItemsAndNesting() {
    let lines = MarkdownText.lines(from: card)
    #expect(lines.map(\.kind) == [
        .text,
        .lead, .item(level: 0, marker: "•"), .item(level: 0, marker: "•"),
        .item(level: 1, marker: "◦"), .item(level: 1, marker: "◦"), .item(level: 0, marker: "•"),
        .text,
        .lead,
        .lead, .item(level: 0, marker: "1."), .item(level: 0, marker: "2."),
        .heading,
        .rule,
    ])
}

@Test func cardLinesKeepInlineSourceAndJoinSoftBreaks() {
    let lines = MarkdownText.lines(from: card)
    #expect(lines[0].text == "Intro paragraph that wraps softly.")
    #expect(lines[1].text == "**What it is** ([topic note](https://example.com/topic))")
    #expect(lines[4].text == "Delivery: ETL.")
    #expect(lines[10].text == "Is any of it built?")
    #expect(lines[12].text == "Heading")
}

@Test func cardLinesMarkTheLastLineOfEachBlock() {
    let lines = MarkdownText.lines(from: card)
    #expect(lines.map(\.endsBlock) == [
        true,
        false, false, false, false, false, true,
        true,
        true,
        false, false, true,
        true,
        true,
    ])
}

@Test func indentedLineAfterAnItemContinuesIt() {
    let lines = MarkdownText.lines(from: "- first part\n  continues here\n- second")
    #expect(lines.map(\.text) == ["first part continues here", "second"])
}

// MARK: rendering

private func paragraphs(_ s: NSAttributedString) -> [(text: String, style: NSParagraphStyle, range: NSRange)] {
    var out: [(String, NSParagraphStyle, NSRange)] = []
    let ns = s.string as NSString
    var location = 0
    while location < ns.length {
        let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
        let style = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as! NSParagraphStyle
        out.append((ns.substring(with: range).trimmingCharacters(in: .newlines), style, range))
        location = NSMaxRange(range)
    }
    return out
}

private func weight(of font: NSFont) -> CGFloat {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    return traits?[.weight] as? CGFloat ?? 0
}

@Test func listItemsHangTheirTextPastTheMarker() {
    let paras = paragraphs(MarkdownText.render(card, style: .saved))
    let idea = paras.first { $0.text.hasSuffix("digital workers.") }!
    let delivery = paras.first { $0.text.hasSuffix("Delivery: ETL.") }!
    #expect(idea.text.hasPrefix("•\t"))
    #expect(idea.style.headIndent > idea.style.firstLineHeadIndent)
    #expect(delivery.style.firstLineHeadIndent > idea.style.firstLineHeadIndent)
    #expect(delivery.style.headIndent > idea.style.headIndent)
}

@Test func listItemsSitCloserTogetherThanBlocks() {
    let paras = paragraphs(MarkdownText.render(card, style: .saved))
    let item = paras.first { $0.text.hasSuffix("digital workers.") }!
    let lastItem = paras.first { $0.text.hasSuffix("kept apart.") }!
    let lead = paras.first { $0.text.hasPrefix("Best questions") }!
    #expect(item.style.paragraphSpacing < lastItem.style.paragraphSpacing)
    #expect(lead.style.paragraphSpacingBefore > 0)
    #expect(lead.style.paragraphSpacing < lastItem.style.paragraphSpacing)
}

@Test func strongRunsAreSemiboldNotBold() {
    let s = MarkdownText.render("**Blockers:** none recorded.", style: .saved)
    let font = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    let plain = s.attribute(.font, at: s.length - 2, effectiveRange: nil) as! NSFont
    #expect(weight(of: font) > weight(of: plain))
    #expect(weight(of: font) < NSFont.Weight.bold.rawValue)
}

@Test func headingsAreLargerThanBody() {
    let s = MarkdownText.render("# Heading\n\nBody text.", style: .saved)
    let heading = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    let body = s.attribute(.font, at: s.length - 2, effectiveRange: nil) as! NSFont
    #expect(heading.pointSize > body.pointSize)
}

@Test func longOrderedListsKeepEveryItemOnOneTextColumn() {
    let list = (1...12).map { "\($0). Item \($0)" }.joined(separator: "\n")
    let s = MarkdownText.render(list, style: .saved)
    let paras = paragraphs(s)
    let columns = Set(paras.map(\.style.headIndent))
    #expect(columns.count == 1)
    let ordinal = s.attribute(.font, at: paras.last!.range.location, effectiveRange: nil) as! NSFont
    let markerWidth = ("12." as NSString).size(withAttributes: [.font: ordinal]).width
    #expect(paras.last!.style.headIndent > markerWidth)
}

@Test func lazyContinuationLinesStayInTheirItem() {
    let lines = MarkdownText.lines(from: "- first item that\nwraps lazily\n- second")
    #expect(lines.map(\.text) == ["first item that wraps lazily", "second"])
}

@Test func softWrappedIntroAboveAListIsOneLead() {
    let lines = MarkdownText.lines(from: "Agents can do\nthese things:\n- search\n- read")
    #expect(lines.map(\.kind) == [.lead, .item(level: 0, marker: "•"), .item(level: 0, marker: "•")])
    #expect(lines[0].text == "Agents can do these things:")
}

@Test func nestingLevelFollowsTheParentNotAbsoluteIndent() {
    let lines = MarkdownText.lines(from: "- Roles:\n    - Delivery\n    - QA\n- Next")
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "•"), .item(level: 1, marker: "◦"),
        .item(level: 1, marker: "◦"), .item(level: 0, marker: "•"),
    ])
}

@Test func uniformlyIndentedListStartsAtTopLevel() {
    let lines = MarkdownText.lines(from: "  - a\n    - b\n  - c")
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "•"), .item(level: 1, marker: "◦"), .item(level: 0, marker: "•"),
    ])
}

@Test func nestingCarriesAcrossALooseList() {
    let lines = MarkdownText.lines(from: "- a\n\n  - b\n\n- c")
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "•"), .item(level: 1, marker: "◦"), .item(level: 0, marker: "•"),
    ])
}

@Test func indentedHeadingIsStillAHeading() {
    #expect(MarkdownText.lines(from: " # Heading").map(\.kind) == [.heading])
    #expect(MarkdownText.lines(from: " # Heading")[0].text == "Heading")
}

@Test func leadLineClosesThePreviousList() {
    let lines = MarkdownText.lines(from: "- a\n  - nested\n\nIntro:\n  - b")
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "•"), .item(level: 1, marker: "◦"),
        .lead, .item(level: 0, marker: "•"),
    ])
}

@Test func ruleWithSurroundingTabIsStillARule() {
    #expect(MarkdownText.lines(from: "---\t").map(\.kind) == [.rule])
    #expect(MarkdownText.lines(from: "\t***").map(\.kind) == [.rule])
}

@Test func whitespaceOnlyLinesAreIgnored() {
    let lines = MarkdownText.lines(from: "Intro\n\n   \n- a\n- b")
    #expect(lines.map(\.kind) == [.text, .item(level: 0, marker: "•"), .item(level: 0, marker: "•")])
}
