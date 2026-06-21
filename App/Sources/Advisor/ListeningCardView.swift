import SwiftUI

/// An injected card in the transcript stream: context / answer / fact-check.
/// Header (type or verdict pill + title/subtitle + status + collapse/dismiss),
/// optional body (Markdown), footer (trigger quote + sources) and follow-up
/// input. Long cards collapse to the header so they don't bury the transcript.
struct ListeningCardView: View {
    let card: Card
    let onToggleExpand: () -> Void
    let onDismiss: () -> Void
    let onCancel: () -> Void
    let onReply: (String) -> Void

    private var isAnswer: Bool { card.kind == "answer" || card.kind == "query" }

    /// The card's accent — verdict colour for a resolved fact-check, kind colour
    /// otherwise. Tints the pill and the border.
    private var accent: Color {
        switch card.kind {
        case "context": Theme.contextViolet
        case "factcheck": verdictColour ?? Theme.textSecondary
        default: Theme.accent
        }
    }

    private var verdictColour: Color? {
        switch card.verdict {
        case .verified: Theme.factGreen
        case .needsContext: Theme.factAmber
        case .misleading: Theme.factRed
        case nil: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if card.isExpanded {
                if isAnswer {
                    Text(card.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !card.body.isEmpty && card.body != "…" {
                    bodyMarkdown
                }
                footer
                if card.state == "done" && !card.replying {
                    CardReplyField(accent: isAnswer ? Theme.accent : nil) { onReply($0) }
                }
            }
        }
        .padding(14)
        .background(Theme.surfaceCard, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.cardRadius)
                .stroke(borderColour, lineWidth: 0.5)
        )
        .shadow(color: Theme.cardShadow, radius: card.isExpanded ? 9 : 6, x: 0, y: card.isExpanded ? 5 : 3)
    }

    private var borderColour: Color {
        if isAnswer { return Theme.accent.opacity(0.30) }
        if card.kind == "factcheck", let c = verdictColour { return c.opacity(0.30) }
        return Theme.hairline
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            pill
            // Answer cards carry their headline in the body; the header shows a
            // subtitle when expanded, the headline when collapsed.
            if isAnswer && card.isExpanded {
                HStack(spacing: 3) {
                    Text("replying to").foregroundStyle(Theme.textTertiary)
                    Text("your question").foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text(card.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textStrong)
                    .lineLimit(card.isExpanded ? 2 : 1)
            }
            status
            Spacer(minLength: 4)
            CardIconButton(system: card.isExpanded ? "chevron.up" : "chevron.down",
                help: card.isExpanded ? "Collapse" : "Expand", action: onToggleExpand)
            CardIconButton(system: "xmark", help: "Dismiss", action: onDismiss)
        }
        .font(.system(size: 12.5))
    }

    @ViewBuilder private var pill: some View {
        switch card.kind {
        case "context":
            TypePill(label: "CONTEXT", colour: Theme.contextViolet, tint: Theme.contextTint, dot: true)
        case "factcheck":
            verdictPill
        default:
            TypePill(label: "ANSWER", colour: Theme.accent, tint: Theme.accentTint, dot: false)
        }
    }

    @ViewBuilder private var verdictPill: some View {
        switch card.verdict {
        case .verified:
            TypePill(label: "VERIFIED", colour: Theme.factGreen, tint: Theme.factGreenTint, glyph: "checkmark")
        case .needsContext:
            TypePill(label: "NEEDS CONTEXT", colour: Theme.factAmber, tint: Theme.factAmberTint, glyph: "exclamationmark")
        case .misleading:
            TypePill(label: "MISLEADING", colour: Theme.factRed, tint: Theme.factRedTint, glyph: "xmark")
        case nil:
            TypePill(label: "FACT-CHECK", colour: Theme.textSecondary, tint: Theme.surfaceCardInset, dot: true)
        }
    }

    @ViewBuilder private var status: some View {
        if card.isResearching {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Researching").foregroundStyle(Theme.textTertiary)
                if !card.replying {
                    CardIconButton(system: "xmark.circle.fill", help: "Skip this card", action: onCancel)
                }
            }
        } else if card.state == "failed" {
            Text("failed").foregroundStyle(Theme.factRed)
        } else if card.state == "cancelled" {
            Text("cancelled").foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: body

    private var bodyMarkdown: some View {
        MarkdownText(markdown: card.body, style: card.kind == "context" ? .context : .answer)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: footer

    @ViewBuilder private var footer: some View {
        let quote: String? =
            isAnswer ? "Grounded in the live conversation" : card.triggerQuote.map { "↳ “\($0)”" }
        if quote != nil || !card.sources.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                if let quote {
                    Text(quote)
                        .font(.system(size: 11).italic())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                ForEach(card.sources) { src in
                    Link(src.label, destination: URL(string: src.url) ?? URL(string: "about:blank")!)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                        .linkCursor()
                }
            }
            .padding(.top, 2)
        }
    }
}

extension View {
    /// Shows the standard pointing-hand cursor while the pointer is over the
    /// view. SwiftUI `Link`/markdown links don't change the cursor on macOS, so
    /// we drive `NSCursor` from the hover state. Push/pop stays balanced because
    /// reaching any other control means moving off this view first.
    func linkCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// A small uppercase type/verdict pill: optional leading dot or SF Symbol glyph.
struct TypePill: View {
    let label: String
    let colour: Color
    let tint: Color
    var dot: Bool = false
    var glyph: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let glyph {
                Image(systemName: glyph).font(.system(size: 8, weight: .bold))
            } else if dot {
                Circle().frame(width: 5, height: 5)
            }
            Text(label)
        }
        .font(.system(size: 10, weight: .bold))
        .kerning(0.5)
        .foregroundStyle(colour)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint, in: RoundedRectangle(cornerRadius: Theme.Metric.pillRadius))
    }
}

/// 26×26 transparent icon button used for collapse/dismiss/skip; lightens on hover.
struct CardIconButton: View {
    let system: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    hovering ? Theme.surfaceCardInset : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Follow-up input shown on a finished card. Owns its draft text; clears on
/// submit. A blue Send for answer cards, neutral otherwise (per the spec).
struct CardReplyField: View {
    var accent: Color? = nil
    let onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("Ask a follow-up about …", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Theme.surfaceCardInset, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 0.5))
                .onSubmit(submit)
            Button("Send", action: submit)
                .buttonStyle(SendButtonStyle(accent: accent))
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onSubmit(t)
        text = ""
    }
}

/// Send button: solid accent (answer) or neutral inset (context/fact-check).
struct SendButtonStyle: ButtonStyle {
    let accent: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(accent == nil ? Theme.textSecondary : Theme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                accent ?? Theme.surfaceCardInset,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accent == nil ? Theme.hairline : .clear, lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
