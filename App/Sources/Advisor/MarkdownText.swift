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
    /// Fenced code block fill; its border is `tableBorder`.
    var codeBlockBackground: NSColor = Theme.nsSurfaceCardSubtle
    /// Text in a block quote; the quote's bar is `tableBorder`.
    var quote: NSColor = Theme.nsTextSecondary

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
/// headings, rules, pipe tables, fenced code blocks and block quotes — the
/// shapes research cards take.
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
            /// A fenced code block; `text` is its source, line breaks kept.
            /// `level` is the list level of the item it belongs to; nil at
            /// the margin.
            case code(level: Int?)
            /// A paragraph indented under an open list item, after the item's
            /// code block, its quote or a blank line: it hangs at the item's text.
            case continuation(level: Int)
        }
        var kind: Kind
        var text: String
        var endsBlock: Bool
        /// The block quotes the line is in, outermost first.
        var quotes: [Quote] = []

        /// A block quote around a line. `id` tells it apart from the quotes
        /// beside it in its parent; `level` is the list level of the item it
        /// belongs to, nil at the margin.
        struct Quote: Hashable {
            var id: Int
            var level: Int?
        }

        var isTable: Bool {
            if case .table = kind { true } else { false }
        }

        /// Drawn in a text block (a table or a code block), which the text
        /// system gives no margins.
        var isTextBlock: Bool {
            switch kind {
            case .table, .code: true
            default: false
            }
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

    /// Card markdown → laid-out lines. Each code fence becomes one code line,
    /// and a block quote's content becomes lines of their own, marked with
    /// the quote (`segments`). The prose between them splits into blocks on blank
    /// lines and around heading lines (`splittingAtHeadings`); a block with
    /// list lines keeps one line per item (a following non-item line
    /// continues it, as in CommonMark), and prose directly above an item
    /// becomes its lead. An item's nesting level is relative to the items
    /// above it, so any consistent indentation (two spaces, four, a tab) nests
    /// one level, and it carries across the blank lines of a loose list.
    static func lines(from markdown: String) -> [Line] {
        var indents: [Int] = []
        var quoteCount = 0
        return segments(markdown.replacingOccurrences(of: "\r\n", with: "\n")).flatMap { segment -> [Line] in
            switch segment {
            case .quote(let content, let indent):
                let quote = Line.Quote(id: quoteCount, level: owner(ofIndent: indent, in: &indents))
                quoteCount += 1
                return lines(from: content).map { line in
                    var line = line
                    line.quotes.insert(quote, at: 0)
                    return line
                }
            case .code(let source, let indent):
                return [Line(kind: .code(level: owner(ofIndent: indent, in: &indents)), text: source, endsBlock: true)]
            case .prose(let prose):
                return proseLines(prose, indents: &indents)
            }
        }
    }

    /// The list level of a block (a code fence or a quote) indented `indent`
    /// columns: the deepest open item it is indented past. It closes any
    /// deeper items. A block at the margin, or under no item, closes the list.
    private static func owner(ofIndent indent: Int, in indents: inout [Int]) -> Int? {
        let level = indent > 0 ? indents.lastIndex { $0 < indent } : nil
        indents = level.map { Array(indents.prefix($0 + 1)) } ?? []
        return level.map { min($0, 3) }
    }

    /// A run of card markdown: prose; the source of a fenced code block; or
    /// the content of a block quote, its `>` markers removed. `indent` is the
    /// indentation of the fence's or the quote's first line, in columns.
    private enum Segment {
        case prose(String)
        case code(String, indent: Int)
        case quote(String, indent: Int)
    }

    /// `markdown` cut at its code fences and block quotes, so that no line of
    /// a fence reaches the prose rules and a blank line in a fence stays in
    /// its block. A fence's lines lose its indentation. A fence ends only at
    /// its closing line, at any indentation; model output often indents code
    /// less than its fence. A fence that is not closed runs to the end, so a
    /// block that is still streaming in shows as code and keeps its shape
    /// when the closing line arrives. Unlike CommonMark, an unclosed fence in
    /// a list item does not end with the item. A quote is a run of lines that
    /// start with `>`; unlike CommonMark, a line without one ends the quote.
    private static func segments(_ markdown: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [String] = []
        var quote: [String] = []
        var quoteIndent = 0
        var code: [String] = []
        var open: (fence: Fence, indent: Int)?
        func endProse() {
            if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))) }
            prose = []
        }
        for line in markdown.components(separatedBy: "\n") {
            if let (fence, indent) = open {
                // A closing line is indented at most three columns past its
                // fence, as in CommonMark, so a deeper fence line is code.
                if fence.isClosed(by: line) && indentColumns(line) <= indent + 3 {
                    out.append(.code(code.joined(separator: "\n"), indent: indent))
                    code = []
                    open = nil
                } else {
                    code.append(dropping(indent, from: line))
                }
                continue
            }
            if let content = quoted(line) {
                endProse()
                if quote.isEmpty { quoteIndent = indentColumns(line) }
                quote.append(content)
                continue
            }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"), indent: quoteIndent)) }
            quote = []
            if let (indent, marker, text) = listItem(line), let fence = Fence(opening: text) {
                // A fence on an item's own line: the item, then its code,
                // indented to where the item's text starts.
                prose.append(String(repeating: " ", count: indent) + marker + " ")
                endProse()
                open = (fence, column(after: line.dropLast(text.count)))
            } else if let fence = Fence(opening: line) {
                endProse()
                open = (fence, indentColumns(line))
            } else {
                prose.append(line)
            }
        }
        if let (_, indent) = open {
            // While a reply streams in, trailing blank lines are not code yet.
            while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
            out.append(.code(code.joined(separator: "\n"), indent: indent))
        }
        if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"), indent: quoteIndent)) }
        endProse()
        return out
    }

    /// A quote line's content: the line without its `>` marker and the space
    /// after it; nil for any other line.
    private static func quoted(_ line: String) -> String? {
        line.wholeMatch(of: #/[ \t]*> ?(.*)/#).map { String($0.1) }
    }

    /// A line's leading whitespace in columns, a tab moving on to the next
    /// multiple of four.
    private static func indentColumns(_ line: String) -> Int {
        column(after: line.prefix { $0 == " " || $0 == "\t" })
    }

    /// The column after `prefix`, a tab moving on to the next multiple of four.
    private static func column(after prefix: Substring) -> Int {
        prefix.reduce(0) { $1 == "\t" ? ($0 / 4 + 1) * 4 : $0 + 1 }
    }

    /// `line` with up to `columns` of its leading whitespace removed.
    private static func dropping(_ columns: Int, from line: String) -> String {
        var rest = Substring(line)
        var dropped = 0
        while dropped < columns, let ch = rest.first, ch == " " || ch == "\t" {
            let width = ch == "\t" ? 4 - dropped % 4 : 1
            rest = rest.dropFirst()
            // A tab that reaches past `columns` keeps its other columns as spaces.
            if dropped + width > columns { return String(repeating: " ", count: dropped + width - columns) + rest }
            dropped += width
        }
        return String(rest)
    }

    /// Prose between code fences → lines; see `lines(from:)`. `indents`
    /// carries the open list levels across a fence.
    private static func proseLines(_ prose: String, indents: inout [Int]) -> [Line] {
        prose
            .components(separatedBy: "\n\n")
            .flatMap(splittingAtHeadings)
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
        if raw.count == 1, let h = headingMarker(raw[0]) {
            indents = []
            return [Line(kind: .heading, text: String(raw[0][h.upperBound...]), endsBlock: false)]
        }
        if let header = raw.indices.dropLast().first(where: { isTableStart(raw, at: $0) }) {
            return tableBlockLines(raw, header: header, indents: &indents)
        }
        guard raw.contains(where: { listItem($0) != nil }) else {
            let text = raw.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            // Indented under an open item, prose continues it; otherwise it
            // closes the list.
            if let level = owner(ofIndent: indentColumns(raw[0]), in: &indents) {
                return [Line(kind: .continuation(level: level), text: text, endsBlock: false)]
            }
            return [Line(kind: isLead(text) ? .lead : .text, text: text, endsBlock: false)]
        }
        // Prose before the block's first item continues an open item when it
        // is indented under it; otherwise it closes the list.
        let continued = listItem(raw[0]) == nil ? owner(ofIndent: indentColumns(raw[0]), in: &indents) : nil
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
                let kind = continued.map { Line.Kind.continuation(level: $0) } ?? .text
                out.append(Line(kind: kind, text: line.trimmingCharacters(in: .whitespaces), endsBlock: false))
            }
        }
        for i in out.indices.dropLast() where out[i].kind == .text {
            if case .item = out[i + 1].kind { out[i].kind = .lead }
        }
        return out
    }

    private static let bullets = ["•", "◦", "▪"]

    /// A heading line's `#` marker and the space after it; nil for any other line.
    private static func headingMarker(_ line: String) -> Range<String.Index>? {
        line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression)
    }

    /// `block` cut so that each heading line starting at the margin is a block
    /// of its own, as if blank lines set it apart: a heading ends the paragraph
    /// or list above it, as in CommonMark (issue #96). An indented `#` line may
    /// belong to the item above, so it stays joined on. Nor is a header row
    /// that starts with `#` above its table's delimiter row cut out. Code
    /// fences never reach here (`segments`), so a `# comment` in one stays
    /// code. Whitespace-only lines go, as in `blockLines`.
    private static func splittingAtHeadings(_ block: String) -> [String] {
        let rows = block.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [String] = []
        var run: [String] = []
        for (i, row) in rows.enumerated() {
            if row.hasPrefix("#"), headingMarker(row) != nil,
                !(rows.indices.contains(i + 1) && isTableStart(rows, at: i))
            {
                out += [run.joined(separator: "\n"), row]
                run = []
                continue
            }
            run.append(row)
        }
        return out + [run.joined(separator: "\n")]
    }

    /// An open code fence: three or more backticks or tildes, as CommonMark has it.
    private struct Fence {
        var mark: Character
        var length: Int

        /// The fence `line` opens. Any indentation is allowed, so a fence
        /// under a list item is still a fence (cards have no indented code
        /// blocks). A backtick fence's info string holds no backtick, so
        /// "```npm i``` …" is inline code.
        init?(opening line: String) {
            guard let m = line.wholeMatch(of: #/[ \t]*(`{3,}|~{3,})(.*)/#),
                let mark = m.1.first, !(mark == "`" && m.2.contains("`"))
            else { return nil }
            self.mark = mark
            length = m.1.count
        }

        /// Closed by a line of at least as many of the same mark, and nothing else.
        func isClosed(by line: String) -> Bool {
            guard let m = line.wholeMatch(of: #/[ \t]*(`{3,}|~{3,})[ \t]*/#) else { return false }
            return m.1.first == mark && m.1.count >= length
        }
    }

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

    /// A list line's indentation (in columns, as `indentColumns`), its marker
    /// token ("-", "*", "+", "1." or "1)") and its text; nil for any other line.
    private static func listItem(_ line: String) -> (Int, String, String)? {
        guard let m = line.firstMatch(of: #/^(\s*)([-*+]|\d+[.)])\s+(.*)$/#) else { return nil }
        let indent = column(after: m.1)
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
        // Where the text of the latest item at each list level starts, so a
        // code block or a quote in an item lines up with it. Kept per quote
        // path: a list in a quote is a list of its own, laid out in the
        // quote's block.
        var textColumns: [[Line.Quote]: [Int: CGFloat]] = [:]
        func textColumn(_ level: Int?, in quotes: [Line.Quote]) -> CGFloat {
            level.flatMap { textColumns[quotes]?[$0] } ?? 0
        }
        // The bar block of each quote, by its path of quotes.
        var bars: [[Line.Quote]: NSTextBlock] = [:]

        for (i, line) in laidOut.enumerated() {
            var para = paragraphStyle(
                for: line, isFirst: i == 0, isLast: i == laidOut.count - 1, size: style.size,
                ordinalColumn: ordinalColumn)
            if case .continuation(let level) = line.kind {
                let hanging = para.mutableCopy() as! NSMutableParagraphStyle
                hanging.firstLineHeadIndent = textColumn(level, in: line.quotes)
                hanging.headIndent = hanging.firstLineHeadIndent
                para = hanging
            }
            let lineAttrs: [NSAttributedString.Key: Any] = [.font: fonts.base, .paragraphStyle: para]
            let start = out.length
            let isLast = i == laidOut.count - 1
            // How many of the line's quotes go on to the next line; the
            // others close with this line.
            let next = isLast ? [] : laidOut[i + 1].quotes
            let kept = zip(line.quotes, next).prefix { $0.0 == $0.1 }.count
            let closesQuote = kept < line.quotes.count
            let colour = line.quotes.isEmpty ? nil : style.quote
            // The line's quote bars, outermost first; an indented quote's bar
            // lines up with its item's text.
            let path = line.quotes.indices.map { depth -> NSTextBlock in
                let key = Array(line.quotes.prefix(depth + 1))
                if let bar = bars[key] { return bar }
                let bar = quoteBar(
                    style, indent: textColumn(line.quotes[depth].level, in: Array(line.quotes.prefix(depth))))
                bars[key] = bar
                return bar
            }
            switch line.kind {
            case .rule:
                var attrs = lineAttrs
                attrs[.foregroundColor] = style.codeBackground
                out.append(NSAttributedString(string: String(repeating: "\u{2500}", count: 24), attributes: attrs))
            case .item(let level, let marker):
                textColumns[line.quotes, default: [:]][level] = para.headIndent
                var attrs = lineAttrs
                attrs[.foregroundColor] = style.marker
                if marker.first?.isNumber == true { attrs[.font] = fonts.ordinal }
                out.append(NSAttributedString(string: marker + "\t", attributes: attrs))
                out.append(inline(line.text, font: fonts.base, para: para, style: style, fonts: fonts, colour: colour))
            case .heading:
                out.append(inline(line.text, font: fonts.heading, para: para, style: style, fonts: fonts, colour: style.strong))
            case .text, .lead, .continuation:
                out.append(inline(line.text, font: fonts.base, para: para, style: style, fonts: fonts, colour: colour))
            case .table(let table):
                out.append(tableText(table, style: style, fonts: fonts))
            case .code(let level):
                out.append(codeText(line.text, indent: textColumn(level, in: line.quotes), style: style, fonts: fonts))
            }
            if !isLast {
                // The newline ends the line's last paragraph, so a table's
                // last cell, or a code block's last line, keeps its block.
                var ending = lineAttrs
                if line.isTextBlock {
                    ending[.paragraphStyle] = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil)
                }
                if case .code = line.kind { ending[.font] = fonts.mono }
                out.append(NSAttributedString(string: "\n", attributes: ending))
                // TextKit ignores text block margins, so an empty line a
                // block's spacing tall stands in for them: inside the quote
                // when the quote goes on, after it when the quote closes.
                if line.isTextBlock && !closesQuote {
                    out.append(NSAttributedString(string: "\n", attributes: blockSpacer(fonts)))
                }
            }
            if !path.isEmpty { quote(out, from: start, in: path, closing: closesQuote) }
            if !isLast && closesQuote {
                // In the quotes that go on, outside the ones that close.
                let spacer = out.length
                out.append(NSAttributedString(string: "\n", attributes: blockSpacer(fonts)))
                if kept > 0 { quote(out, from: spacer, in: Array(path.prefix(kept)), closing: false) }
            }
        }
        return out
    }

    /// A block quote's block, from `indent` to the card's edge: a bar down
    /// its left edge, its text clear of it.
    private static func quoteBar(_ style: MarkdownTextStyle, indent: CGFloat) -> NSTextBlock {
        let m = Theme.Metric.self
        let bar = NSTextBlock()
        bar.setValue(100, type: .percentageValueType, for: .width)
        bar.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        bar.setBorderColor(style.tableBorder, for: .minX)
        bar.setWidth(m.cardQuoteBar, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setWidth(m.cardQuotePadding, type: .absoluteValueType, for: .padding, edge: .minX)
        return bar
    }

    /// Puts each paragraph of `out` from `start` in the quote blocks `path`
    /// (outermost first), around any block it is already in. Closing the
    /// quote drops its last paragraph's spacing, which would lengthen the
    /// bar; a spacer line after the quote stands in for it.
    private static func quote(_ out: NSMutableAttributedString, from start: Int, in path: [NSTextBlock], closing: Bool) {
        // The live backing string, not a copy of the whole text per quoted line.
        let ns = out.mutableString
        var location = start
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let current = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let p = (current ?? .default).mutableCopy() as! NSMutableParagraphStyle
            p.textBlocks = path + p.textBlocks
            if closing && NSMaxRange(range) == ns.length { p.paragraphSpacing = 0 }
            out.addAttribute(.paragraphStyle, value: p, range: range)
            location = NSMaxRange(range)
        }
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

    /// A fenced code block's source, not parsed: one paragraph per line, all
    /// in one text block with the table's border and a fill, from `indent`
    /// to the card's edge. Long lines wrap at the card's edge.
    private static func codeText(
        _ source: String, indent: CGFloat, style: MarkdownTextStyle, fonts: Fonts
    ) -> NSAttributedString {
        let m = Theme.Metric.self
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.backgroundColor = style.codeBlockBackground
        block.setBorderColor(style.tableBorder)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        for edge: NSRectEdge in [.minX, .maxX] {
            block.setWidth(m.cardCodePaddingX, type: .absoluteValueType, for: .padding, edge: edge)
        }
        for edge: NSRectEdge in [.minY, .maxY] {
            block.setWidth(m.cardCodePaddingY, type: .absoluteValueType, for: .padding, edge: edge)
        }
        let p = NSMutableParagraphStyle()
        p.textBlocks = [block]
        if indent > 0 {
            // TextKit fills a block's margin too, so an indented block sits in
            // an unfilled block whose padding holds it at `indent`.
            let inset = NSTextBlock()
            inset.setValue(100, type: .percentageValueType, for: .width)
            inset.setWidth(indent, type: .absoluteValueType, for: .padding, edge: .minX)
            p.textBlocks.insert(inset, at: 0)
        }
        p.lineSpacing = m.cardCodeLineSpacing
        // An empty block still needs a character to carry its block.
        return NSAttributedString(
            string: source.isEmpty ? " " : source,
            attributes: [.font: fonts.mono, .foregroundColor: style.body, .paragraphStyle: p])
    }

    private static func blockSpacer(_ fonts: Fonts) -> [NSAttributedString.Key: Any] {
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
        case .text, .rule, .table, .code, .continuation:
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
                ns.addAttributes([.font: fonts.italic, .foregroundColor: style.emphasis ?? colour ?? style.body], range: range)
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
