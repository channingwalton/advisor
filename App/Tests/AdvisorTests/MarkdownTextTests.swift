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

// MARK: tables

private typealias Table = MarkdownText.Table

private let pricing = """
| Option | Cost |
|:--|--:|
| **A** | £1 |
| B | £2 |
"""

@Test func pipeTableBecomesOneTableLine() {
    let lines = MarkdownText.lines(from: pricing)
    #expect(lines.map(\.kind) == [
        .table(Table(alignments: [.left, .right], header: ["Option", "Cost"], rows: [["**A**", "£1"], ["B", "£2"]])),
    ])
    #expect(lines.map(\.endsBlock) == [true])
}

@Test func tableAlignmentComesFromTheDelimiterColons() {
    let lines = MarkdownText.lines(from: "a | b | c\n--- | :-: | ---:\n1 | 2 | 3")
    #expect(lines.map(\.kind) == [
        .table(Table(alignments: [.natural, .center, .right], header: ["a", "b", "c"], rows: [["1", "2", "3"]])),
    ])
}

@Test func raggedRowsFitTheHeaderAndEscapedPipesStayInTheirCell() {
    let lines = MarkdownText.lines(from: "| a | b |\n|---|---|\n| 1 |\n| x \\| y | 2 | extra |")
    #expect(lines.map(\.kind) == [
        .table(Table(alignments: [.natural, .natural], header: ["a", "b"], rows: [["1", ""], ["x | y", "2"]])),
    ])
}

@Test func proseDirectlyAboveATableIsItsLead() {
    let lines = MarkdownText.lines(from: "Compared:\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.")
    #expect(lines.count == 3)
    #expect(lines[0].kind == .lead)
    #expect(lines[0].text == "Compared:")
    guard case .table = lines[1].kind else { Issue.record("expected a table, got \(lines[1].kind)"); return }
    #expect(lines[2].kind == .text)
}

@Test func linesThatOnlyLookTabularStayProse() {
    // Header and delimiter disagree on the column count; a lone pipe line; a
    // setext-style underline with no pipes.
    #expect(MarkdownText.lines(from: "a | b\n|---|").map(\.kind) == [.text])
    #expect(MarkdownText.lines(from: "Either a | b, then.").map(\.kind) == [.text])
    #expect(MarkdownText.lines(from: "Title\n---").map(\.kind) == [.text])
}

@Test func tableCellsRenderAsAGridOfTextTableBlocks() {
    let s = MarkdownText.render("Intro.\n\n" + pricing + "\n\nAfter.", style: .answer)
    let paras = paragraphs(s)
    #expect(paras.map(\.text) == ["Intro.", "Option", "Cost", "A", "£1", "B", "£2", "", "After."])
    let cells = paras.dropFirst().dropLast(2).map { $0.style.textBlocks.first as? NSTextTableBlock }
    #expect(cells.allSatisfy { $0 != nil })
    let table = cells.first!!.table
    #expect(table.numberOfColumns == 2)
    #expect(cells.allSatisfy { $0?.table === table })
    #expect(cells.map { $0!.startingRow } == [0, 0, 1, 1, 2, 2])
    #expect(cells.map { $0!.startingColumn } == [0, 1, 0, 1, 0, 1])
    #expect(paras.first!.style.textBlocks.isEmpty)
    #expect(paras.last!.style.textBlocks.isEmpty)
    #expect(paras[2].style.alignment == .right)
}

@Test func headerCellsAreStrongAndBodyCellsKeepInlineMarkdown() {
    let s = MarkdownText.render(pricing, style: .answer)
    let paras = paragraphs(s)
    let header = s.attribute(.font, at: paras[0].range.location, effectiveRange: nil) as! NSFont
    let boldBody = s.attribute(.font, at: paras[2].range.location, effectiveRange: nil) as! NSFont
    let plainBody = s.attribute(.font, at: paras[4].range.location, effectiveRange: nil) as! NSFont
    #expect(weight(of: header) > weight(of: plainBody))
    #expect(weight(of: boldBody) > weight(of: plainBody))
}

@Test func aTableEndingTheCardAddsNoTrailingLine() {
    let s = MarkdownText.render("| a | b |\n|---|---|\n| 1 | |", style: .answer)
    #expect(!s.string.hasSuffix("\n"))
    #expect(paragraphs(s).count == 4)
}

@MainActor
@Test func tableCellsInARowSitSideBySide() {
    let tv = IntrinsicHeightTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
    _ = tv.layoutManager
    tv.textContainer?.widthTracksTextView = true
    MarkdownText(markdown: pricing, style: .answer).apply(to: tv)
    let lm = tv.layoutManager!
    lm.ensureLayout(for: tv.textContainer!)
    let ns = tv.string as NSString
    func rect(_ text: String) -> NSRect {
        let glyphs = lm.glyphRange(forCharacterRange: ns.range(of: text), actualCharacterRange: nil)
        return lm.boundingRect(forGlyphRange: glyphs, in: tv.textContainer!)
    }
    #expect(abs(rect("Option").midY - rect("Cost").midY) < 1)
    #expect(rect("Cost").minX > rect("Option").maxX)
    #expect(rect("B").minY > rect("A").maxY)
}

@Test func columnsTakeTheirNaturalWidthWhenTheyFit() {
    #expect(FittedTextTable.columnWidths(minimums: [10, 20], naturals: [40, 60], available: 200) == [40, 60])
}

@Test func narrowColumnsKeepTheirNaturalWidthAndTheWidestTakesTheRest() {
    // "Option" and "Monthly cost" each fit an even share; "Notes" wraps in what is left.
    #expect(FittedTextTable.columnWidths(minimums: [40, 50, 80], naturals: [73, 86, 640], available: 621) == [73, 86, 462])
}

@Test func columnsShareTheShortfallInProportionToTheirSlack() {
    // The first column would fit an even share (150), but at its natural width
    // the second couldn't have its widest word, so both share the 10 spare
    // above their minimums, half each for equal slack.
    #expect(FittedTextTable.columnWidths(minimums: [40, 250], naturals: [140, 350], available: 300) == [45, 255])
}

@Test func narrowColumnsKeepTheirWidestWordWhenAWideOneMustBreak() {
    // A long URL can't fit whatever it gets, so "Option" keeps its word.
    #expect(FittedTextTable.columnWidths(minimums: [50, 600], naturals: [60, 600], available: 300) == [50, 250])
}

@Test func columnsScaleTheirMinimumsWhenNoneFitAnEvenShare() {
    #expect(FittedTextTable.columnWidths(minimums: [200, 400], naturals: [300, 500], available: 300) == [100, 200])
}

private let comparison = """
| Option | Notes |
|---|---|
| DynamoDB | Single-writer, fine for local tools and small single-user apps that never need concurrent writers |

After.
"""

@MainActor
private func laidOut(_ markdown: String, width: CGFloat) -> (NSLayoutManager, NSTextContainer, NSString) {
    let tv = IntrinsicHeightTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    _ = tv.layoutManager
    tv.textContainer?.widthTracksTextView = true
    tv.textContainer?.lineFragmentPadding = 0
    MarkdownText(markdown: markdown, style: .answer).apply(to: tv)
    tv.layoutManager!.ensureLayout(for: tv.textContainer!)
    return (tv.layoutManager!, tv.textContainer!, tv.string as NSString)
}

@MainActor
private func cellFrame(_ text: String, in layout: (NSLayoutManager, NSTextContainer, NSString)) -> NSRect {
    let (lm, _, ns) = layout
    let glyph = lm.glyphIndexForCharacter(at: ns.range(of: text).location)
    return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
}

@MainActor
@Test func aShortColumnKeepsItsNaturalWidthBesideAWrappingOne() {
    let layout = laidOut(comparison, width: 360)
    let option = cellFrame("DynamoDB", in: layout)
    let notes = cellFrame("Single-writer", in: layout)
    let dynamo = ("DynamoDB" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Theme.Metric.cardBodySize)])
    #expect(option.width >= ceil(dynamo.width))
    #expect(option.width < 100)
    #expect(notes.width > 2 * option.width)
}

@MainActor
@Test func aTableNeverOverflowsTheCard() {
    for width in [240.0, 360, 700] {
        let (lm, container, _) = laidOut(comparison, width: width)
        #expect(lm.usedRect(for: container).width <= width)
    }
}

@MainActor
@Test func aSmallTableShrinksToItsContent() {
    let (lm, container, ns) = laidOut("| a | b |\n|---|---|\n| 1 | 2 |", width: 700)
    let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: ns.length), actualCharacterRange: nil)
    #expect(lm.boundingRect(forGlyphRange: glyphs, in: container).maxX < 200)
}

@MainActor
@Test func textAfterATableIsSpacedOffIt() {
    let layout = laidOut(comparison, width: 360)
    let gap = cellFrame("After.", in: layout).minY - cellFrame("DynamoDB", in: layout).maxY
    #expect(gap >= Theme.Metric.cardBlockSpacing + Theme.Metric.cardCellPaddingY)
}

@Test func eachGridLineIsDrawnOnce() {
    let paras = paragraphs(MarkdownText.render(pricing, style: .answer))
    let cells = paras.map { $0.style.textBlocks.first as! NSTextTableBlock }
    for cell in cells {
        let lastColumn = cell.startingColumn == 1, lastRow = cell.startingRow == 2
        #expect(cell.width(for: .border, edge: .minX) == 1)
        #expect(cell.width(for: .border, edge: .minY) == 1)
        #expect(cell.width(for: .border, edge: .maxX) == (lastColumn ? 1 : 0))
        #expect(cell.width(for: .border, edge: .maxY) == (lastRow ? 1 : 0))
    }
}

@MainActor
@Test func aCodeOnlyCellSitsOnItsRowsBaseline() {
    let (lm, _, ns) = laidOut(pricing.replacingOccurrences(of: "| B |", with: "| `SQLite` |"), width: 400)
    func baseline(_ text: String) -> CGFloat {
        let glyph = lm.glyphIndexForCharacter(at: ns.range(of: text).location)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + lm.location(forGlyphAt: glyph).y
    }
    #expect(abs(baseline("SQLite") - baseline("£2")) < 0.5)
}

@Test func aLineWithoutPipesEndsTheTable() {
    let lines = MarkdownText.lines(from: "| a |\n|---|\n| 1 |\nThen prose.")
    #expect(lines.map(\.kind) == [
        .table(Table(alignments: [.natural], header: ["a"], rows: [["1"]])), .text,
    ])
    #expect(lines[1].text == "Then prose.")
}

@Test func anEscapedBackslashBeforeTheClosingPipeStillClosesTheRow() {
    let lines = MarkdownText.lines(from: "| a | C:\\\\|\n|---|---|\n| 1 | D:\\\\|")
    #expect(lines.map(\.kind) == [
        .table(Table(alignments: [.natural, .natural], header: ["a", "C:\\\\"], rows: [["1", "D:\\\\"]])),
    ])
}

@MainActor
@Test func consecutiveTablesAreSpacedApart() {
    let (lm, _, ns) = laidOut("| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |", width: 300)
    func frame(_ text: String) -> NSRect {
        lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: ns.range(of: text).location), effectiveRange: nil)
    }
    let gap = frame("b").minY - frame("1").maxY
    #expect(gap >= Theme.Metric.cardBlockSpacing + 2 * Theme.Metric.cardCellPaddingY)
}

@Test func headerEmphasisAndCodeStaySemibold() {
    let s = MarkdownText.render("| *Cost* | `id` |\n|---|---|\n| 1 | 2 |", style: .answer)
    let ns = s.string as NSString
    let italic = s.attribute(.font, at: ns.range(of: "Cost").location, effectiveRange: nil) as! NSFont
    let code = s.attribute(.font, at: ns.range(of: "id").location, effectiveRange: nil) as! NSFont
    #expect(weight(of: italic) > 0)
    #expect(italic.fontDescriptor.symbolicTraits.contains(.italic))
    #expect(weight(of: code) > 0)
    #expect(code.isFixedPitch)
}

@Test func aNoBreakSpaceKeepsItsWordsTogetherInTheColumnMinimum() {
    let s = MarkdownText.render("| Price | x |\n|---|---|\n| £1\u{00A0}000 | y |", style: .answer)
    let ns = s.string as NSString
    let style = s.attribute(.paragraphStyle, at: ns.range(of: "£1").location, effectiveRange: nil) as! NSParagraphStyle
    let table = (style.textBlocks.first as! NSTextTableBlock).table as! FittedTextTable
    let price = NSAttributedString(string: "£1\u{00A0}000", attributes: [.font: NSFont.systemFont(ofSize: Theme.Metric.cardBodySize)])
    #expect(table.minimums[0] >= floor(price.size().width))
}

@MainActor
@Test func anEmptyColumnBesideAnUnbreakableOneStaysInsideTheCard() {
    let url = "https://example.com/a/very/long/path/without/any/spaces/that/cannot/fit"
    for width in [200.0, 300] {
        let (lm, container, _) = laidOut("| a | | ref |\n|---|---|---|\n| x | | \(url) |", width: width)
        #expect(lm.usedRect(for: container).width <= width)
    }
}
