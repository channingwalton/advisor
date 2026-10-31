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

/// A heading needn't stand alone in its block (issue #96).
@Test func headingWithTextDirectlyUnderItIsStillAHeading() {
    let lines = MarkdownText.lines(from: "## Summary\nThe gist.")
    #expect(lines.map(\.kind) == [.heading, .text])
    #expect(lines.map(\.text) == ["Summary", "The gist."])
    let s = MarkdownText.render("## Summary\nThe gist.", style: .answer)
    let heading = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
    let body = s.attribute(.font, at: s.length - 2, effectiveRange: nil) as! NSFont
    #expect(heading.pointSize > body.pointSize)
}

@Test func headingWithAListDirectlyUnderItIsStillAHeading() {
    let lines = MarkdownText.lines(from: "## Options\n- a\n- b")
    #expect(lines.map(\.kind) == [.heading, .item(level: 0, marker: "•"), .item(level: 0, marker: "•")])
    #expect(lines.map(\.text) == ["Options", "a", "b"])
}

/// Laid out as if blank lines set each heading apart.
@Test func headingDirectlyUnderAParagraphOrListEndsIt() {
    let lines = MarkdownText.lines(from: "Intro.\n## Next\n- a\n  - b\n### Last\n- c")
    #expect(lines.map(\.kind) == [
        .text, .heading, .item(level: 0, marker: "•"), .item(level: 1, marker: "◦"),
        .heading, .item(level: 0, marker: "•"),
    ])
    #expect(lines.map(\.text) == ["Intro.", "Next", "a", "b", "Last", "c"])
    #expect(lines == MarkdownText.lines(from: "Intro.\n\n## Next\n\n- a\n  - b\n\n### Last\n\n- c"))
}

@Test func hashLineInACodeFenceIsNotAHeading() {
    let lines = MarkdownText.lines(from: "```\n# install\nbrew install jq\n```")
    #expect(!lines.contains { $0.kind == .heading })
}

@Test func hashLineInAFenceAcrossABlankLineIsNotAHeading() {
    let lines = MarkdownText.lines(from: "```bash\n# install\nbrew install jq\n\n# configure\njq . f\n```")
    #expect(!lines.contains { $0.kind == .heading })
}

@Test func headingAfterAFenceAcrossABlankLineIsAHeading() {
    let lines = MarkdownText.lines(from: "```\nfoo\n\nbar\n```\n## Next\nThe gist.")
    #expect(lines.suffix(2).map(\.kind) == [.heading, .text])
    #expect(lines.suffix(2).map(\.text) == ["Next", "The gist."])
}

@Test func inlineCodeAtALineStartDoesNotOpenAFence() {
    let lines = MarkdownText.lines(from: "```npm i``` first:\n## Setup\nRun it.")
    #expect(lines.map(\.kind) == [.text, .heading, .text])
}

@Test func aFenceClosesOnlyOnItsOwnMarker() {
    #expect(!MarkdownText.lines(from: "~~~\n```\n# not a heading\nx\n~~~").contains { $0.kind == .heading })
    #expect(!MarkdownText.lines(from: "````\n```\n# not a heading\nx\n````").contains { $0.kind == .heading })
}

// MARK: - Fenced code blocks (issue #107)

/// The code sections of the "Scala type lambdas" card (#107): a fence with no
/// blank line in it, and two that hold blank lines.
private let scalaCard = """
### Scala 2 — type projection hack
```scala
// "Kind projector" compiler plugin syntax:
def foo[F[_]: Monad] = ...
foo[({ type L[A] = Either[String, A] })#L]  // anonymous type member + projection
```
Anonymous structural types with a type member, accessed via `#` projection.

### Scala 3 — native syntax
```scala
// Type lambda literal:
type EitherString = [A] =>> Either[String, A]

// Inline at call site:
foo[[A] =>> Either[String, A]]
```
`[A] =>> F` is a first-class type-level function.

```scala
// Monoidal structure: `pure` (unit) + `flatten` (multiplication)

trait Monad[F[_]] extends Functor[F]:
  def pure[A](a: A): F[A]          // identity / unit
```
"""

private let code = Line.Kind.code(level: nil)

@Test func aFenceIsOneCodeLineWithItsLinesIndentationAndBlankLines() {
    let lines = MarkdownText.lines(from: scalaCard)
    #expect(lines.map(\.kind) == [.heading, code, .text, .heading, code, .text, code])
    #expect(lines[1].text == """
        // "Kind projector" compiler plugin syntax:
        def foo[F[_]: Monad] = ...
        foo[({ type L[A] = Either[String, A] })#L]  // anonymous type member + projection
        """)
    #expect(lines[4].text == """
        // Type lambda literal:
        type EitherString = [A] =>> Either[String, A]

        // Inline at call site:
        foo[[A] =>> Either[String, A]]
        """)
    #expect(lines[6].text == """
        // Monoidal structure: `pure` (unit) + `flatten` (multiplication)

        trait Monad[F[_]] extends Functor[F]:
          def pure[A](a: A): F[A]          // identity / unit
        """)
}

@Test func markdownInAFenceStaysSource() {
    let source = "# not a heading\n- not an item\n| a | b |\n|---|---|\n**not bold** `x`\n---"
    #expect(MarkdownText.lines(from: "```\n\(source)\n```") == [Line(kind: code, text: source, endsBlock: true)])
}

@Test func aFenceSplitsTheParagraphAroundIt() {
    let lines = MarkdownText.lines(from: "Run:\n```\nmake\n```\nThen test.")
    #expect(lines.map(\.kind) == [.text, code, .text])
    #expect(lines.map(\.text) == ["Run:", "make", "Then test."])
    #expect(lines.map(\.endsBlock) == [true, true, true])
}

@Test func anUnclosedFenceRunsToTheEnd() {
    #expect(MarkdownText.lines(from: "Streaming:\n~~~\nline one\n\nline two").last
        == Line(kind: code, text: "line one\n\nline two", endsBlock: true))
}

@Test func anIndentedFenceDropsItsIndentationFromItsLines() {
    #expect(MarkdownText.lines(from: "  ```\n  a\n    b\n  ```").map(\.text) == ["a\n  b"])
}

@Test func aCodeBlockRendersItsSourceMonospacedInOneFilledBlock() throws {
    let s = MarkdownText.render("Before.\n\n```\nlet x = **1**\n\n  `y`\n```\nAfter.", style: .answer)
    #expect(s.string == "Before.\nlet x = **1**\n\n  `y`\n\nAfter.")
    let paras = paragraphs(s)
    #expect(paras.map(\.text) == ["Before.", "let x = **1**", "", "  `y`", "", "After."])
    let blocks = paras[1...3].map { $0.style.textBlocks.first }
    let block = try #require(blocks[0])
    #expect(blocks.allSatisfy { $0 === block })
    #expect(!(block is NSTextTableBlock))
    #expect(block.backgroundColor == MarkdownTextStyle.answer.codeBlockBackground)
    #expect(paras[0].style.textBlocks.isEmpty && paras[5].style.textBlocks.isEmpty)
    let font = s.attribute(.font, at: paras[1].range.location, effectiveRange: nil) as! NSFont
    #expect(font.isFixedPitch)
}

@Test func aFenceUnderAnItemBelongsToItAndTheListGoesOn() {
    let lines = MarkdownText.lines(from: """
        1. Install:
           ```bash
           brew install jq
           ```
        2. Configure:
           - nested
             ```
             x
             ```
        """)
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "1."), .code(level: 0), .item(level: 0, marker: "2."),
        .item(level: 1, marker: "◦"), .code(level: 1),
    ])
    #expect(lines[1].text == "brew install jq")
}

@Test func aFenceAtTheMarginEndsTheList() {
    let lines = MarkdownText.lines(from: "- a\n```\nx\n```\n  - b")
    #expect(lines.map(\.kind) == [.item(level: 0, marker: "•"), code, .item(level: 0, marker: "•")])
}

@Test func anIndentedFenceAfterProseIsAtTheMargin() {
    #expect(MarkdownText.lines(from: "- a\n\nText.\n  ```\n  x\n  ```").last?.kind == code)
}

@MainActor
private func textFrame(_ text: String, in layout: (NSLayoutManager, NSTextContainer, NSString)) -> NSRect {
    let (lm, container, ns) = layout
    let glyphs = lm.glyphRange(forCharacterRange: ns.range(of: text), actualCharacterRange: nil)
    return lm.boundingRect(forGlyphRange: glyphs, in: container)
}

@MainActor
@Test func aCodeBlockUnderAnItemLinesUpWithTheItemsText() {
    let inset = 1 + Theme.Metric.cardCodePaddingX
    let atMargin = laidOut("```\nmargin\n```", width: 360)
    #expect(abs(textFrame("margin", in: atMargin).minX - inset) < 1)
    let nested = laidOut("- Install:\n  ```\n  brew install jq\n  ```", width: 360)
    let item = textFrame("Install", in: nested)
    #expect(abs(textFrame("brew", in: nested).minX - (item.minX + inset)) < 1)
    // The margin narrows the block, so its lines still end inside the card.
    #expect(cellFrame("brew", in: nested).maxX <= 360 - inset + 1)
    #expect(cellFrame("margin", in: atMargin).maxX <= 360 - inset + 1)
}

// MARK: - Block quotes (issue #107)

@Test func aQuoteHoldsMarkdownOfItsOwn() {
    let lines = MarkdownText.lines(from: "Before.\n\n> **Note:** quoted\n> - item\n>\n> ```\n> # code\n> ```\n\nAfter.")
    #expect(lines.map(\.kind) == [.text, .lead, .item(level: 0, marker: "•"), code, .text])
    #expect(lines.map(\.text) == ["Before.", "**Note:** quoted", "item", "# code", "After."])
    #expect(lines.map(\.quotes.count) == [0, 1, 1, 1, 0])
    #expect(Set(lines[1...3].map(\.quotes)).count == 1)
}

@Test func quotesApartAreSeparateAndAQuoteCanNest() {
    let apart = MarkdownText.lines(from: "> a\n\n> b")
    #expect(apart.map(\.quotes.count) == [1, 1])
    #expect(apart[0].quotes != apart[1].quotes)
    let nested = MarkdownText.lines(from: "> a\n>\n> > b")
    #expect(nested.map(\.quotes.count) == [1, 2])
    #expect(nested[1].quotes.first == nested[0].quotes.first)
}

@Test func aLineWithoutAMarkerEndsTheQuote() {
    #expect(MarkdownText.lines(from: "> a\nb").map(\.quotes.count) == [1, 0])
}

@Test func aMarkerInAFenceOrMidLineIsNoQuote() {
    #expect(MarkdownText.lines(from: "```\n> x\n```") == [Line(kind: code, text: "> x", endsBlock: true)])
    #expect(MarkdownText.lines(from: "a > b").map(\.quotes.count) == [0])
}

@Test func aQuoteRendersInOneBarredBlockInTheQuoteColour() throws {
    let style = MarkdownTextStyle.answer
    let s = MarkdownText.render("> one\n>\n> two\n> ```\n> x\n> ```\n\nAfter.", style: style)
    let paras = paragraphs(s)
    let quoted = paras.filter { ["one", "two", "x"].contains($0.text) }
    #expect(quoted.count == 3)
    let bar = try #require(quoted[0].style.textBlocks.first)
    #expect(quoted.allSatisfy { $0.style.textBlocks.first === bar })
    #expect(bar.width(for: .border, edge: .minX) == Theme.Metric.cardQuoteBar)
    #expect(bar.width(for: .border, edge: .maxX) == 0)
    // The code block nests inside the quote.
    #expect(quoted[2].style.textBlocks.count == 2)
    #expect(paras.last?.text == "After." && paras.last?.style.textBlocks.isEmpty == true)
    #expect(s.attribute(.foregroundColor, at: paras[0].range.location, effectiveRange: nil) as? NSColor == style.quote)
}

@MainActor
@Test func quotedTextClearsTheBarAndTextAfterTheQuoteIsSpacedOffIt() {
    let layout = laidOut("> one\n> two\n\nAfter.", width: 360)
    let m = Theme.Metric.self
    #expect(abs(textFrame("one", in: layout).minX - (m.cardQuoteBar + m.cardQuotePadding)) < 1)
    #expect(cellFrame("After.", in: layout).minY - cellFrame("two", in: layout).maxY >= m.cardBlockSpacing)
}

@Test func aFenceOnAListMarkerLineIsTheItemsCode() {
    let lines = MarkdownText.lines(from: "1. ```bash\n   brew install jq\n   ```\n2. Configure it\n\nMore prose")
    #expect(lines.map(\.kind) == [.item(level: 0, marker: "1."), .code(level: 0), .item(level: 0, marker: "2."), .text])
    #expect(lines.map(\.text) == ["", "brew install jq", "Configure it", "More prose"])
}

/// Unlike CommonMark, an unclosed fence in an item runs to the end, as one at
/// the margin does, so a streaming block keeps its shape.
@Test func anUnclosedFenceInAnItemRunsToTheEnd() {
    let lines = MarkdownText.lines(from: "1. Install:\n   ```bash\n   brew install jq\n\n2. Configure\n\nMore prose")
    #expect(lines.map(\.kind) == [.item(level: 0, marker: "1."), .code(level: 0)])
    #expect(lines[1].text == "brew install jq\n\n2. Configure\n\nMore prose")
    #expect(MarkdownText.lines(from: "1. a\n   ```\n   x\n\n   y\n   ```").last?.text == "x\n\ny")
}

@Test func aDeeplyIndentedFenceLineInAMarginFenceIsCode() {
    let source = "- step\n      ```\n      x\n      ```"
    #expect(MarkdownText.lines(from: "```markdown\n\(source)\n```") == [Line(kind: code, text: source, endsBlock: true)])
}

@Test func aTabPartlyInsideAFencesIndentKeepsItsOtherColumns() {
    // The fence's code starts at column 3; the tab reaches column 4.
    #expect(MarkdownText.lines(from: "1. ```\n\t  x\n   ```").last?.text == "   x")
}

@Test func aStreamingFenceUnderAnItemKeepsUnderIndentedCodeAsCode() {
    let lines = MarkdownText.lines(from: "- ```python\n# setup\nimport x")
    #expect(lines.map(\.kind) == [.item(level: 0, marker: "•"), .code(level: 0)])
    #expect(lines[1].text == "# setup\nimport x")
}

@MainActor
@Test func aCodeBlockUnderAnItemIsFilledFromItsBorderOnly() throws {
    var style = MarkdownTextStyle.answer
    style.codeBlockBackground = .red
    let tv = IntrinsicHeightTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 10))
    _ = tv.layoutManager
    tv.textContainer?.widthTracksTextView = true
    tv.textContainer?.lineFragmentPadding = 0
    tv.drawsBackground = false
    MarkdownText(markdown: "- Install:\n  ```\n  brew install jq\n  ```", style: style).apply(to: tv)
    let (lm, container) = (tv.layoutManager!, tv.textContainer!)
    lm.ensureLayout(for: container)
    tv.frame.size.height = ceil(lm.usedRect(for: container).maxY) + 20
    let ns = tv.string as NSString
    func frame(_ text: String) -> NSRect {
        lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: ns.range(of: text), actualCharacterRange: nil), in: container)
    }
    let column = frame("Install").minX
    let row = frame("brew").midY
    let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
    tv.cacheDisplay(in: tv.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / tv.bounds.width
    func isFill(_ x: CGFloat) -> Bool {
        guard let c = rep.colorAt(x: Int(x * scale), y: Int(row * scale))?.usingColorSpace(.deviceRGB) else { return false }
        return c.alphaComponent > 0.5 && c.redComponent > 0.8 && c.greenComponent < 0.3
    }
    #expect(isFill(column + 4))
    #expect(!isFill(column / 2))
}

@Test func aClosedFenceKeepsLinesIndentedLessThanItself() {
    let lines = MarkdownText.lines(from: "- ```bash\nbrew install jq\n```\nMore text\n\n## Next")
    #expect(lines.map(\.kind) == [.item(level: 0, marker: "•"), .code(level: 0), .text, .heading])
    #expect(lines[1].text == "brew install jq")
    #expect(MarkdownText.lines(from: "Text.\n  ```\nfoo\n  ```").map(\.text) == ["Text.", "foo"])
    // A diff whose lines look like list items stays one code block.
    let diff = MarkdownText.lines(from: "1. Change:\n   ```diff\n- old\n+ new\n   ```\n2. Next")
    #expect(diff.map(\.kind) == [.item(level: 0, marker: "1."), .code(level: 0), .item(level: 0, marker: "2.")])
    #expect(diff[1].text == "- old\n+ new")
}

@Test func textAfterAnItemsCodeBlockStaysInTheItem() {
    let lines = MarkdownText.lines(from: """
        1. Install:
           ```
           brew install jq
           ```
           then run it
        2. Configure
           - sub
        """)
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "1."), .code(level: 0), .continuation(level: 0),
        .item(level: 0, marker: "2."), .item(level: 1, marker: "◦"),
    ])
    #expect(lines[2].text == "then run it")
}

@MainActor
@Test func textThatContinuesAnItemHangsAtItsText() {
    let layout = laidOut("1. Install:\n   ```\n   x\n   ```\n   then run it", width: 360)
    #expect(abs(textFrame("then", in: layout).minX - textFrame("Install", in: layout).minX) < 1)
}

@Test func italicInAHeadingTakesTheHeadingColour() {
    let style = MarkdownTextStyle.answer
    let s = MarkdownText.render("## Using *Monad* here", style: style)
    let at = (s.string as NSString).range(of: "Monad").location
    #expect(s.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == style.strong)
}

@Test func aFenceOnAMarkerLineDropsTheItemsWholeIndent() {
    #expect(MarkdownText.lines(from: "1.  ```\n    x\n    ```").map(\.text) == ["", "x"])
    #expect(MarkdownText.lines(from: "-\t```\n\tx\n\t```").map(\.text) == ["", "x"])
}

@Test func whitespaceAfterAQuoteMarkerIsIndentationInTheQuote() {
    #expect(MarkdownText.lines(from: ">\t- item\n>\t- two").map(\.kind) == [
        .item(level: 0, marker: "•"), .item(level: 0, marker: "•"),
    ])
    #expect(MarkdownText.lines(from: ">   ```\n>   x\n>   ```").map(\.text) == ["x"])
}

@MainActor
@Test func aListInAQuoteLeavesTheOuterItemsColumnAlone() {
    let layout = laidOut("1. Step\n   > - inner\n   ```\n   code\n   ```", width: 360)
    let step = textFrame("Step", in: layout)
    #expect(abs(textFrame("code", in: layout).minX - (step.minX + 1 + Theme.Metric.cardCodePaddingX)) < 1)
}

@Test func aStreamingFenceShowsNoBlankLineForATrailingNewline() {
    #expect(MarkdownText.lines(from: "```\nfoo\n").last?.text == "foo")
    #expect(MarkdownText.lines(from: "```\nfoo\n\n```").last?.text == "foo\n")
}

@Test func aTabIndentedFenceDropsItsTabAndAnEmptyFenceStillRenders() {
    #expect(MarkdownText.lines(from: "\t```\n\tx\n\t\ty\n\t```").map(\.text) == ["x\n\ty"])
    #expect(paragraphs(MarkdownText.render("```\n```", style: .answer)).first?.style.textBlocks.count == 1)
}

@Test func emphasisAndItemsInAQuoteKeepTheQuoteColour() {
    let style = MarkdownTextStyle.answer
    let s = MarkdownText.render("> This is *really* important\n> - an *item*", style: style)
    let ns = s.string as NSString
    for word in ["This", "really", "an", "item"] {
        #expect(s.attribute(.foregroundColor, at: ns.range(of: word).location, effectiveRange: nil) as? NSColor == style.quote)
    }
}

@Test func aNestedQuoteClosingInsideItsParentEndsWithoutSpacing() throws {
    let paras = paragraphs(MarkdownText.render("> a\n>\n> > b\n>\n> c", style: .answer))
    let b = try #require(paras.firstIndex { $0.text == "b" })
    let outer = paras[b].style.textBlocks[0]
    #expect(paras[b].style.textBlocks.count == 2)
    #expect(paras[b].style.paragraphSpacing == 0)
    // The gap after it is a spacer in the outer quote only.
    #expect(paras[b + 1].text.isEmpty && paras[b + 1].style.textBlocks.count == 1)
    #expect(paras[b + 1].style.textBlocks.first === outer)
    #expect(paras[b + 2].text == "c" && paras[b + 2].style.textBlocks.first === outer)
}

@Test func aQuoteUnderAnItemBelongsToItAndTheListGoesOn() {
    let lines = MarkdownText.lines(from: "1. Step one\n   > **Note:** back up first\n2. Step two\n   - sub")
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "1."), .text, .item(level: 0, marker: "2."), .item(level: 1, marker: "◦"),
    ])
    #expect(lines[1].quotes.first?.level == 0)
    #expect(MarkdownText.lines(from: "> at the margin").first?.quotes.first?.level == nil)
}

@MainActor
@Test func aQuoteUnderAnItemLinesUpWithTheItemsText() {
    let layout = laidOut("- Step\n  > note", width: 360)
    let m = Theme.Metric.self
    let step = textFrame("Step", in: layout)
    #expect(abs(textFrame("note", in: layout).minX - (step.minX + m.cardQuoteBar + m.cardQuotePadding)) < 1)
}

@MainActor
@Test func aQuoteUnderAnItemStaysInsideTheCard() {
    let note = "a long note that wraps across the card more than once at this width"
    for width in [240.0, 360] {
        let layout = laidOut("- Step\n  > \(note)", width: width)
        #expect(cellFrame("a long", in: layout).maxX <= width + 0.5)
        #expect(layout.0.usedRect(for: layout.1).maxX <= width + 0.5)
    }
}

@MainActor
@Test func aTableInAQuoteStaysInsideTheCard() {
    let quoted = comparison.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    for width in [240.0, 360, 700] {
        let (lm, container, _) = laidOut(quoted, width: width)
        #expect(lm.usedRect(for: container).width <= width)
    }
}

@MainActor
@Test func textAfterAQuoteThatEndsInCodeIsSpacedOffIt() {
    let layout = laidOut("> ```\n> x\n> ```\n\nAfter.", width: 360)
    #expect(cellFrame("After.", in: layout).minY - cellFrame("x", in: layout).maxY >= Theme.Metric.cardBlockSpacing)
}

@MainActor
@Test func aCodeBlockSpansTheCardAndTextAfterItIsSpacedOffIt() {
    let layout = laidOut("```\nshort\n```\nAfter.", width: 360)
    let line = cellFrame("short", in: layout)
    #expect(line.width > 300)
    #expect(cellFrame("After.", in: layout).minY - line.maxY >= Theme.Metric.cardBlockSpacing)
}

@Test func aHashHeaderCellAboveADelimiterRowIsATable() {
    for markdown in ["# | Task\n--|--\n1 | Ship", "# | Task\n   \n--|--\n1 | Ship"] {
        let lines = MarkdownText.lines(from: markdown)
        #expect(lines.count == 1)
        #expect(lines.first?.isTable == true)
    }
}

/// An indented `#` line may belong to the item above, so it stays joined on.
@Test func indentedHashLineUnderAnItemLeavesTheListNested() {
    let lines = MarkdownText.lines(from: "- Step one\n  # Note\n  - sub a\n  - sub b")
    #expect(lines.map(\.kind) == [
        .item(level: 0, marker: "•"), .item(level: 1, marker: "◦"), .item(level: 1, marker: "◦"),
    ])
}

@Test func tabIndentedHashLineInASnippetUnderAnItemIsNotAHeading() {
    let lines = MarkdownText.lines(from: "1. Install:\n\t```bash\n\t# install deps\n\tbrew install jq\n\t```")
    #expect(!lines.contains { $0.kind == .heading })
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
