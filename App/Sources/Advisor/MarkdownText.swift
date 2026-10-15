import AppKit
import SwiftUI

/// Styling for a card's rich text. NSColors (not SwiftUI Colors) because the text
/// is drawn by an AppKit text view; values mirror the `Theme` tokens the cards
/// used under MarkdownUI.
struct MarkdownTextStyle: Hashable {
    var size: CGFloat = Theme.Metric.cardBodySize
    var body: NSColor
    var code: NSColor
    var codeBackground: NSColor
    var link: NSColor
    /// Italic-run colour; `nil` keeps the body colour.
    var emphasis: NSColor?
    /// Bold runs and headings.
    var strong: NSColor = Theme.nsTextStrong
    /// List bullets and ordinals.
    var marker: NSColor = Theme.nsTextTertiary
    /// Table grid lines and header-row fill.
    var tableBorder: NSColor = Theme.nsHairlineStrong
    var tableHeader: NSColor = Theme.nsSurfaceCardSubtle

    /// Answer / fact-check cards — accent code + links.
    static let answer = MarkdownTextStyle(
        body: Theme.nsTextBody, code: Theme.nsAccent, codeBackground: Theme.nsAccentTint,
        link: Theme.nsAccent, emphasis: nil)
    /// Context cards — violet code, accent links.
    static let context = MarkdownTextStyle(
        body: Theme.nsTextBody, code: Theme.nsContextCodeText, codeBackground: Theme.nsContextCodeBg,
        link: Theme.nsAccent, emphasis: nil)
    /// Saved-session cards — muted italic footer, accent links.
    static let saved = MarkdownTextStyle(
        body: Theme.nsTextBody, code: Theme.nsAccent, codeBackground: Theme.nsAccentTint,
        link: Theme.nsAccent, emphasis: Theme.nsTextMuted)
}

/// Renders card markdown as selectable rich text in an `NSTextView` so links get
/// the native pointing-hand cursor — SwiftUI `Text`/MarkdownUI never change the
/// cursor over links (issue #26). Inline bold/italic/code/links, laid out by
/// `lines(from:)` into paragraphs, lead lines, hanging (nested) list items,
/// headings, rules and pipe tables — the shapes research cards take.
struct MarkdownText: NSViewRepresentable {
    let markdown: String
    var style: MarkdownTextStyle

    func makeNSView(context: Context) -> IntrinsicHeightTextView {
        // Convenience init owns the TextKit stack (storage included); touching
        // `layoutManager` forces the TextKit 1 fallback so height measurement
        // works — same pattern as the transcript view (issue #12).
        let tv = IntrinsicHeightTextView(frame: .zero)
        _ = tv.layoutManager
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        apply(to: tv)
        return tv
    }

    func updateNSView(_ tv: IntrinsicHeightTextView, context: Context) {
        apply(to: tv)
    }

    /// Render `markdown` into `tv`, unless it already shows this markdown in this
    /// style (`renderedContent`). Returns whether it rendered. The colours are
    /// dynamic, so a skipped update still follows light/dark changes.
    @discardableResult
    func apply(to tv: IntrinsicHeightTextView) -> Bool {
        let content = AnyHashable([AnyHashable(markdown), AnyHashable(style)])
        guard tv.renderedContent != content else { return false }
        tv.renderedContent = content
        // Accent links, no underline (the hand cursor is the affordance).
        tv.linkTextAttributes = [
            .foregroundColor: style.link,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: 0,
        ]
        tv.textStorage?.setAttributedString(Self.render(markdown, style: style))
        tv.invalidateIntrinsicContentSize()
        return true
    }

    /// One laid-out paragraph of a card body: its role, its inline-markdown
    /// source, and whether it closes its blank-line-separated block (which sets
    /// the space after it).
    struct Line: Equatable {
        enum Kind: Equatable {
            /// A prose paragraph, soft line breaks joined with spaces.
            case text
            /// A short bold line that introduces what follows ("**Progress**",
            /// "**What it is** (…)"): spaced off above and bound to its list below.
            case lead
            /// A list item. `level` comes from its indentation; `marker` is a
            /// level bullet, or the typed ordinal ("1.") for an ordered list.
            case item(level: Int, marker: String)
            case heading
            case rule
            /// A GitHub-flavoured pipe table; `text` is empty.
            case table(Table)
        }
        var kind: Kind
        var text: String
        var endsBlock: Bool

        var isTable: Bool {
            if case .table = kind { true } else { false }
        }
    }

    /// A pipe table's cells as inline-markdown source. Every body row has one
    /// cell per header cell (short rows padded, long rows cut, as GFM does).
    struct Table: Equatable {
        /// Per column, from the delimiter row's colons; `.natural` without any.
        var alignments: [NSTextAlignment]
        var header: [String]
        var rows: [[String]]
    }

    /// Card markdown → laid-out lines. Blocks split on blank lines; a block with
    /// list lines keeps one line per item (a following non-item line continues
    /// it, as in CommonMark), and prose directly above an item becomes its lead.
    /// An item's nesting level is relative to the items above it, so any
    /// consistent indentation (two spaces, four, a tab) nests one level, and it
    /// carries across the blank lines of a loose list.
    static func lines(from markdown: String) -> [Line] {
        var indents: [Int] = []
        return markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .flatMap { block -> [Line] in
                var lines = blockLines(block, indents: &indents)
                if !lines.isEmpty { lines[lines.count - 1].endsBlock = true }
                return lines
            }
    }

    /// One block's lines. `indents` holds the indentation of each open list
    /// level; a block that doesn't open with a list item closes them.
    private static func blockLines(_ block: String, indents: inout [Int]) -> [Line] {
        if isThematicBreak(block) {
            indents = []
            return [Line(kind: .rule, text: "", endsBlock: false)]
        }
        // Whitespace-only lines are blank lines, not content.
        let raw = block.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if raw.count == 1, let h = raw[0].range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
            indents = []
            return [Line(kind: .heading, text: String(raw[0][h.upperBound...]), endsBlock: false)]
        }
        if let header = raw.indices.dropLast().first(where: { isTableStart(raw, at: $0) }) {
            return tableBlockLines(raw, header: header, indents: &indents)
        }
        guard raw.contains(where: { listItem($0) != nil }) else {
            indents = []
            let text = raw.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            return [Line(kind: isLead(text) ? .lead : .text, text: text, endsBlock: false)]
        }
        if listItem(raw[0]) == nil { indents = [] }
        var out: [Line] = []
        for line in raw {
            if let (indent, token, text) = listItem(line) {
                while let top = indents.last, top > indent { indents.removeLast() }
                if indents.last != indent { indents.append(indent) }
                let level = min(indents.count - 1, 3)
                let marker = token.first?.isNumber == true ? token : bullets[level % bullets.count]
                out.append(Line(kind: .item(level: level, marker: marker), text: text, endsBlock: false))
            } else if !out.isEmpty {
                // A wrapped item or a wrapped paragraph: join it on.
                out[out.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                out.append(Line(kind: .text, text: line.trimmingCharacters(in: .whitespaces), endsBlock: false))
            }
        }
        for i in out.indices.dropLast() where out[i].kind == .text {
            if case .item = out[i + 1].kind { out[i].kind = .lead }
        }
        return out
    }

    private static let bullets = ["•", "◦", "▪"]

    /// A block holding a pipe table: the lines above it (prose there becomes
    /// its lead), the table, then whatever follows its last piped row.
    private static func tableBlockLines(_ raw: [String], header: Int, indents: inout [Int]) -> [Line] {
        var out = header > 0 ? blockLines(raw[..<header].joined(separator: "\n"), indents: &indents) : []
        if out.last?.kind == .text { out[out.count - 1].kind = .lead }
        indents = []
        let columns = cells(raw[header]).count
        let body = raw[(header + 2)...].prefix { $0.contains("|") }
        let table = Table(
            alignments: cells(raw[header + 1]).map(alignment),
            header: cells(raw[header]),
            rows: body.map { row in
                let c = cells(row)
                return Array(c.prefix(columns)) + Array(repeating: "", count: max(0, columns - c.count))
            })
        out.append(Line(kind: .table(table), text: "", endsBlock: false))
        let rest = raw[(header + 2 + body.count)...]
        if !rest.isEmpty { out += blockLines(rest.joined(separator: "\n"), indents: &indents) }
        return out
    }

    /// Whether `raw[i]` is a table's header row: piped, and followed by a piped
    /// delimiter row (`---`, `:--`, `--:` or `:-:` cells) of the same width.
    private static func isTableStart(_ raw: [String], at i: Int) -> Bool {
        guard raw[i].contains("|"), raw[i + 1].contains("|") else { return false }
        let marks = cells(raw[i + 1])
        return marks.count == cells(raw[i]).count && marks.allSatisfy { $0.wholeMatch(of: #/:?-+:?/#) != nil }
    }

    private static func alignment(_ mark: String) -> NSTextAlignment {
        switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
        case (true, true): .center
        case (false, true): .right
        case (true, false): .left
        case (false, false): .natural
        }
    }

    /// A table row's trimmed cells: outer pipes dropped, split on unescaped
    /// pipes, `\|` kept as a pipe (other escapes are left for the inline parser).
    private static func cells(_ row: String) -> [String] {
        var line = Substring(row.trimmingCharacters(in: .whitespaces))
        if line.hasPrefix("|") { line = line.dropFirst() }
        var cells = [""]
        var escaped = false
        var closed = false
        for ch in line {
            closed = false
            if escaped {
                cells[cells.count - 1] += ch == "|" ? "|" : "\\\(ch)"
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append("")
                closed = true
            } else {
                cells[cells.count - 1].append(ch)
            }
        }
        if escaped { cells[cells.count - 1] += "\\" }
        // A closing pipe ends the last cell rather than opening another.
        if closed { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A list line's indentation (in columns, a tab counting four), its marker
    /// token ("-", "*", "+", "1." or "1)") and its text; nil for any other line.
    private static func listItem(_ line: String) -> (Int, String, String)? {
        guard let m = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.*)$/#) else { return nil }
        let indent = m.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return (indent, String(m.2), String(m.3))
    }

    /// A line that is bold from end to end (one strong run) reads as a lead.
    private static func isLead(_ text: String) -> Bool {
        text.count > 4 && text.hasPrefix("**") && text.hasSuffix("**")
            && !text.dropFirst(2).dropLast(2).contains("**")
    }

    /// Card markdown → styled `NSAttributedString`. See the type doc for scope.
    static func render(_ markdown: String, style: MarkdownTextStyle) -> NSAttributedString {
        let fonts = Fonts(size: style.size)
        let laidOut = lines(from: markdown)
        let out = NSMutableAttributedString()
        // Wide enough for the card's widest ordinal ("10.") plus a gap, so every
        // numbered item's text starts on the same column.
        let widestOrdinal = laidOut.compactMap { line -> CGFloat? in
            guard case .item(_, let marker) = line.kind, marker.first?.isNumber == true else { return nil }
            return (marker as NSString).size(withAttributes: [.font: fonts.ordinal]).width
        }.max() ?? 0
        let ordinalColumn = max(Theme.Metric.cardOrdinalColumn, ceil(widestOrdinal) + 6)

        for (i, line) in laidOut.enumerated() {
            let para = paragraphStyle(
                for: line, isFirst: i == 0, isLast: i == laidOut.count - 1, size: style.size,
                ordinalColumn: ordinalColumn)
            let lineAttrs: [NSAttributedString.Key: Any] = [.font: fonts.base, .paragraphStyle: para]
            switch line.kind {
            case .rule:
                var attrs = lineAttrs
                attrs[.foregroundColor] = style.codeBackground
                out.append(NSAttributedString(string: String(repeating: "\u{2500}", count: 24), attributes: attrs))
            case .item(_, let marker):
                var attrs = lineAttrs
                attrs[.foregroundColor] = style.marker
                if marker.first?.isNumber == true { attrs[.font] = fonts.ordinal }
                out.append(NSAttributedString(string: marker + "\t", attributes: attrs))
                out.append(inline(line.text, font: fonts.base, para: para, style: style, fonts: fonts))
            case .heading:
                out.append(inline(line.text, font: fonts.heading, para: para, style: style, fonts: fonts, colour: style.strong))
            case .text, .lead:
                out.append(inline(line.text, font: fonts.base, para: para, style: style, fonts: fonts))
            case .table(let table):
                out.append(tableText(table, style: style, fonts: fonts))
            }
            if i < laidOut.count - 1 {
                // The newline ends the line's last paragraph, so a table's
                // last cell keeps its cell block.
                var ending = lineAttrs
                if line.isTable {
                    ending[.paragraphStyle] = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil)
                }
                out.append(NSAttributedString(string: "\n", attributes: ending))
                // TextKit ignores table and cell margins, so an empty line a
                // block's spacing tall stands in for the table's.
                if line.isTable { out.append(NSAttributedString(string: "\n", attributes: tableSpacer(fonts))) }
            }
        }
        return out
    }

    /// A table as one `FittedTextTable` (TextKit 1, which the view forces): a
    /// paragraph per cell in its own cell block, row by row. Every cell but the
    /// last ends with a newline; the line separator (or the end of the text)
    /// ends the last. A hairline grid, each line drawn once (cells draw their
    /// top and left edges, the last row and column close the frame), and a
    /// filled strong header row.
    private static func tableText(_ table: Table, style: MarkdownTextStyle, fonts: Fonts) -> NSAttributedString {
        let m = Theme.Metric.self
        let rows = [table.header] + table.rows
        let columns = table.header.count
        let grid = FittedTextTable()
        grid.numberOfColumns = columns
        grid.collapsesBorders = true
        grid.hidesEmptyCells = false
        let out = NSMutableAttributedString()
        var minimums = Array(repeating: CGFloat(0), count: columns)
        var naturals = minimums
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.enumerated() {
                let block = grid.cell(row: r, column: c)
                block.setBorderColor(style.tableBorder)
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minX)
                block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
                if c == columns - 1 { block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxX) }
                if r == rows.count - 1 { block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY) }
                block.setWidth(m.cardCellPaddingX, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(m.cardCellPaddingX, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(m.cardCellPaddingY, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(m.cardCellPaddingY, type: .absoluteValueType, for: .padding, edge: .maxY)
                if r == 0 { block.backgroundColor = style.tableHeader }
                let p = NSMutableParagraphStyle()
                p.alignment = table.alignments[c]
                // A line of only (smaller) code is as tall as body text, so it sits on the row's baseline.
                p.minimumLineHeight = ceil(fonts.base.ascender - fonts.base.descender + fonts.base.leading)
                p.textBlocks = [block]
                let attrs: [NSAttributedString.Key: Any] = [.font: fonts.base, .paragraphStyle: p]
                var text = r == 0
                    ? inline(cell, font: fonts.strong, para: p, style: style, fonts: fonts, colour: style.strong)
                    : inline(cell, font: fonts.base, para: p, style: style, fonts: fonts)
                // An empty cell still needs a character to carry its block.
                if text.length == 0 { text = NSAttributedString(string: " ", attributes: attrs) }
                naturals[c] = max(naturals[c], ceil(text.size().width))
                minimums[c] = max(minimums[c], widestWord(in: text))
                out.append(text)
                out.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        grid.minimums = minimums
        grid.naturals = naturals
        out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        return out
    }

    private static func tableSpacer(_ fonts: Fonts) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = Theme.Metric.cardBlockSpacing
        p.maximumLineHeight = Theme.Metric.cardBlockSpacing
        return [.font: fonts.base, .paragraphStyle: p]
    }

    /// Spaces a line may break at: not the no-break ones.
    private static let breakingSpaces = CharacterSet.whitespaces.subtracting(
        CharacterSet(charactersIn: "\u{00A0}\u{2007}\u{202F}"))

    /// The width of the widest run of `text` between breaking spaces, as laid out.
    private static func widestWord(in text: NSAttributedString) -> CGFloat {
        var widest: CGFloat = 0
        let ns = text.string as NSString
        var location = 0
        while location < ns.length {
            let gap = ns.rangeOfCharacter(from: breakingSpaces, range: NSRange(location: location, length: ns.length - location))
            let end = gap.location == NSNotFound ? ns.length : gap.location
            if end > location {
                widest = max(widest, ceil(text.attributedSubstring(from: NSRange(location: location, length: end - location)).size().width))
            }
            location = end + max(gap.length, 1)
        }
        return widest
    }

    private struct Fonts {
        let base, strong, italic, strongItalic, heading, mono, strongMono, ordinal: NSFont

        init(size: CGFloat) {
            base = NSFont.systemFont(ofSize: size)
            strong = NSFont.systemFont(ofSize: size, weight: .semibold)
            italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            strongItalic = NSFontManager.shared.convert(strong, toHaveTrait: .italicFontMask)
            heading = NSFont.systemFont(ofSize: size + 1, weight: .semibold)
            mono = NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular)
            strongMono = NSFont.monospacedSystemFont(ofSize: size - 2, weight: .semibold)
            ordinal = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        }
    }

    /// Spacing by role: list items sit closer together than blocks, leads and
    /// headings get room above and hug what follows, and items hang their text
    /// past the marker on a tab stop.
    private static func paragraphStyle(
        for line: Line, isFirst: Bool, isLast: Bool, size: CGFloat, ordinalColumn: CGFloat
    ) -> NSParagraphStyle {
        let m = Theme.Metric.self
        let p = NSMutableParagraphStyle()
        p.lineSpacing = size * m.cardLineSpacingRatio
        p.paragraphSpacing = line.endsBlock ? m.cardBlockSpacing : m.cardItemSpacing
        switch line.kind {
        case .item(let level, let marker):
            let indent = CGFloat(level) * m.cardListIndent
            let column = marker.first?.isNumber == true ? ordinalColumn : m.cardBulletColumn
            p.firstLineHeadIndent = indent
            p.headIndent = indent + column
            p.tabStops = [NSTextTab(textAlignment: .left, location: indent + column)]
        case .lead, .heading:
            p.paragraphSpacingBefore = isFirst ? 0 : m.cardLeadSpacingBefore
            p.paragraphSpacing = m.cardItemSpacing
        case .text, .rule, .table:
            break
        }
        if isLast { p.paragraphSpacing = 0 }
        return p
    }

    /// Inline markdown (bold/italic/code/links) → attributed runs on `font`.
    private static func inline(
        _ text: String, font: NSFont, para: NSParagraphStyle, style: MarkdownTextStyle, fonts: Fonts,
        colour: NSColor? = nil
    ) -> NSAttributedString {
        let parsed =
            (try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnly, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
        let ns = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let full = NSRange(location: 0, length: ns.length)
        ns.addAttributes([.font: font, .foregroundColor: colour ?? style.body, .paragraphStyle: para], range: full)
        // A table header is strong throughout, its italic and code runs included.
        let header = font === fonts.strong
        ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue ?? (value as? UInt) else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                ns.addAttributes(
                    [.font: header ? fonts.strongMono : fonts.mono, .foregroundColor: style.code,
                     .backgroundColor: style.codeBackground],
                    range: range)
            } else if intent.contains(.stronglyEmphasized), intent.contains(.emphasized) {
                ns.addAttributes([.font: fonts.strongItalic, .foregroundColor: style.strong], range: range)
            } else if intent.contains(.stronglyEmphasized) {
                ns.addAttributes([.font: font === fonts.heading ? font : fonts.strong, .foregroundColor: style.strong], range: range)
            } else if intent.contains(.emphasized), header {
                ns.addAttributes([.font: fonts.strongItalic, .foregroundColor: style.strong], range: range)
            } else if intent.contains(.emphasized) {
                ns.addAttributes([.font: fonts.italic, .foregroundColor: style.emphasis ?? style.body], range: range)
            }
        }
        return ns
    }

    /// A block of `---`/`***`/`___` (3+), optionally spaced — a horizontal rule.
    private static func isThematicBreak(_ block: String) -> Bool {
        guard !block.contains("\n") else { return false }
        let stripped = block.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }
}

/// An `NSTextTable` that sizes its columns to their content at the width it is
/// laid out in, as a browser does. TextKit 1's automatic layout splits the
/// width evenly whatever the content, and scales fixed cell widths that don't
/// fit, so each layout at a new width sets them afresh.
final class FittedTextTable: NSTextTable {
    /// Per column, content widths in points: the widest word (any narrower
    /// breaks a word) and the longest cell on one line.
    var minimums: [CGFloat] = []
    var naturals: [CGFloat] = []
    /// Weak: each cell holds its table.
    private let cells = NSHashTable<NSTextTableBlock>.weakObjects()
    private var fittedWidth: CGFloat?

    /// A one-row, one-column cell of this table, sized with it.
    func cell(row: Int, column: Int) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: self, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cells.add(block)
        return block
    }

    override func rect(
        for block: NSTextTableBlock, layoutAt startingPoint: NSPoint, in rect: NSRect,
        textContainer: NSTextContainer, characterRange charRange: NSRange
    ) -> NSRect {
        if fittedWidth != rect.width { fit(to: rect.width) }
        return super.rect(
            for: block, layoutAt: startingPoint, in: rect, textContainer: textContainer,
            characterRange: charRange)
    }

    /// Archives (drag, copy) as a plain table: the fitting is this view's.
    override var classForCoder: AnyClass { NSTextTable.self }

    /// Sets every cell's content width for a table `width` wide, after each
    /// column's padding and the grid lines, with a point spare for rounding.
    private func fit(to width: CGFloat) {
        fittedWidth = width
        guard let any = cells.anyObject, minimums.count == numberOfColumns else { return }
        let padding = any.width(for: .padding, edge: .minX) + any.width(for: .padding, edge: .maxX)
        let chrome = CGFloat(numberOfColumns) * padding + CGFloat(numberOfColumns + 1) + 1
        let widths = Self.columnWidths(minimums: minimums, naturals: naturals, available: width - chrome)
        for cell in cells.allObjects {
            cell.setValue(widths[cell.startingColumn], type: .absoluteValueType, for: .width)
        }
    }

    /// Column content widths for `available` points: every column's natural
    /// width when they all fit. Otherwise, narrowest first, a column that fits
    /// an even share of what is left keeps its natural width, so long as the
    /// rest can still have their widest words; the rest get their minimum plus
    /// a share of what remains in proportion to their slack. When even the
    /// widest words don't fit, words must break somewhere: narrow columns keep
    /// their widest word in the same way, and the rest are scaled into what
    /// remains.
    static func columnWidths(minimums: [CGFloat], naturals: [CGFloat], available: CGFloat) -> [CGFloat] {
        if naturals.reduce(0, +) <= available { return naturals }
        let wordsFit = minimums.reduce(0, +) < available
        let wanted = wordsFit ? naturals : minimums
        var widths = minimums
        var open = wanted.indices.sorted { wanted[$0] < wanted[$1] }
        var left = available
        while let i = open.first {
            let othersMinimum = wordsFit ? open.dropFirst().reduce(0) { $0 + minimums[$1] } : 0
            guard wanted[i] <= left / CGFloat(open.count), left - wanted[i] >= othersMinimum else { break }
            widths[i] = wanted[i]
            left -= wanted[i]
            open.removeFirst()
        }
        let openMinimum = open.reduce(0) { $0 + minimums[$1] }
        guard wordsFit else {
            for i in open { widths[i] = openMinimum > 0 ? minimums[i] * max(left, 0) / openMinimum : 0 }
            return widths
        }
        // Not every column fits, so `open` keeps one whose natural width
        // exceeds `left`, which still covers the open minimums.
        let openNatural = open.reduce(0) { $0 + naturals[$1] }
        for i in open {
            widths[i] = minimums[i] + (naturals[i] - minimums[i]) * (left - openMinimum) / (openNatural - openMinimum)
        }
        return widths
    }
}

/// Read-only text view that reports a height fitting its content at the current
