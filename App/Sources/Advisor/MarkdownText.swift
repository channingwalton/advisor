import AppKit
import SwiftUI

/// Styling for a card's rich text. NSColors (not SwiftUI Colors) because the text
/// is drawn by an AppKit text view; values mirror the `Theme` tokens the cards
/// used under MarkdownUI.
struct MarkdownTextStyle {
    var size: CGFloat = Theme.Metric.cardBodySize
    var body: NSColor
    var code: NSColor
    var codeBackground: NSColor
    var link: NSColor
    /// Italic-run colour; `nil` keeps the body colour.
    var emphasis: NSColor?

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
/// cursor over links (issue #26). Inline-first: bold/italic/code/links across
/// blank-line-separated paragraphs, with light handling for lists, headings and
/// thematic breaks, which suits the app's concise card bodies. Block layout
/// (nested lists, tables) degrades to plain lines.
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

    private func apply(to tv: IntrinsicHeightTextView) {
        // Accent links, no underline (the hand cursor is the affordance).
        tv.linkTextAttributes = [
            .foregroundColor: style.link,
            .cursor: NSCursor.pointingHand,
            .underlineStyle: 0,
        ]
        let attr = Self.render(markdown, style: style)
        if tv.textStorage?.isEqual(to: attr) != true {
            tv.textStorage?.setAttributedString(attr)
        }
        tv.invalidateIntrinsicContentSize()
    }

    /// Card markdown → styled `NSAttributedString`. See the type doc for scope.
    static func render(_ markdown: String, style: MarkdownTextStyle) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: style.size)
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        let heading = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: style.size + 1), toHaveTrait: .boldFontMask)
        let mono = NSFont.monospacedSystemFont(ofSize: style.size - 2, weight: .regular)

        let para = NSMutableParagraphStyle()
        para.lineSpacing = style.size * 0.2
        para.paragraphSpacing = Theme.Metric.paragraphSpacing

        let out = NSMutableAttributedString()
        let blocks =
            markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for (i, rawBlock) in blocks.enumerated() {
            if isThematicBreak(rawBlock) {
                out.append(
                    NSAttributedString(
                        string: String(repeating: "\u{2500}", count: 24),
                        attributes: [.font: base, .foregroundColor: style.codeBackground, .paragraphStyle: para]))
                if i < blocks.count - 1 { out.append(NSAttributedString(string: "\n")) }
                continue
            }

            let (text, isHeading) = normalise(rawBlock)
            let parsed: AttributedString
            if let a = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnly, failurePolicy: .returnPartiallyParsedIfPossible))
            {
                parsed = a
            } else {
                parsed = AttributedString(text)
            }
            let ns = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            let full = NSRange(location: 0, length: ns.length)
            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: isHeading ? heading : base, .foregroundColor: style.body, .paragraphStyle: para,
            ]
            ns.addAttributes(baseAttrs, range: full)
            ns.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
                guard let raw = (value as? NSNumber)?.uintValue ?? (value as? UInt) else { return }
                let intent = InlinePresentationIntent(rawValue: raw)
                if intent.contains(.code) {
                    let codeAttrs: [NSAttributedString.Key: Any] = [
                        .font: mono, .foregroundColor: style.code, .backgroundColor: style.codeBackground,
                    ]
                    ns.addAttributes(codeAttrs, range: range)
                } else if intent.contains(.stronglyEmphasized), intent.contains(.emphasized) {
                    ns.addAttribute(.font, value: boldItalic, range: range)
                } else if intent.contains(.stronglyEmphasized) {
                    ns.addAttribute(.font, value: bold, range: range)
                } else if intent.contains(.emphasized) {
                    ns.addAttributes(
                        [.font: italic, .foregroundColor: style.emphasis ?? style.body], range: range)
                }
            }
            out.append(ns)
            if i < blocks.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    /// A block of `---`/`***`/`___` (3+), optionally spaced — a horizontal rule.
    private static func isThematicBreak(_ block: String) -> Bool {
        guard !block.contains("\n") else { return false }
        let stripped = block.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    /// Prepare a block for inline parsing: strip a heading marker (returning a
    /// heading flag), bullet-mark list lines (keeping their line breaks), and
    /// otherwise collapse soft line breaks to spaces like CommonMark.
    private static func normalise(_ block: String) -> (text: String, isHeading: Bool) {
        let lines = block.components(separatedBy: "\n")
        if lines.count == 1, let h = lines[0].range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            return (String(lines[0][h.upperBound...]), true)
        }
        let isList = lines.contains {
            $0.range(of: #"^\s*([-*+]\s+|\d+[.)]\s+)"#, options: .regularExpression) != nil
        }
        if isList {
            let marked = lines.map { line -> String in
                if let r = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                    return "\u{2022}\u{00A0}" + line[r.upperBound...]
                }
                return line
            }
            return (marked.joined(separator: "\n"), false)
        }
        return (lines.joined(separator: " "), false)
    }
}

/// Read-only text view that reports a height fitting its content at the current
