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
/// headings and rules — the shapes research cards take. Tables degrade to
/// plain lines.
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
        }
        var kind: Kind
        var text: String
        var endsBlock: Bool
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
            }
            if i < laidOut.count - 1 { out.append(NSAttributedString(string: "\n", attributes: lineAttrs)) }
        }
        return out
    }

    private struct Fonts {
        let base, strong, italic, strongItalic, heading, mono, ordinal: NSFont

        init(size: CGFloat) {
            base = NSFont.systemFont(ofSize: size)
            strong = NSFont.systemFont(ofSize: size, weight: .semibold)
            italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            strongItalic = NSFontManager.shared.convert(strong, toHaveTrait: .italicFontMask)
            heading = NSFont.systemFont(ofSize: size + 1, weight: .semibold)
            mono = NSFont.monospacedSystemFont(ofSize: size - 2, weight: .regular)
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
        case .text, .rule:
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
        ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue ?? (value as? UInt) else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            if intent.contains(.code) {
                ns.addAttributes(
                    [.font: fonts.mono, .foregroundColor: style.code, .backgroundColor: style.codeBackground],
                    range: range)
            } else if intent.contains(.stronglyEmphasized), intent.contains(.emphasized) {
                ns.addAttributes([.font: fonts.strongItalic, .foregroundColor: style.strong], range: range)
            } else if intent.contains(.stronglyEmphasized) {
                ns.addAttributes([.font: font === fonts.heading ? font : fonts.strong, .foregroundColor: style.strong], range: range)
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

/// Read-only text view that reports a height fitting its content at the current
