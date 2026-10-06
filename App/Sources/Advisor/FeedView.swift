import SwiftUI

/// What the shared feed can do, supplied by each window: the live recording acts
/// on its store and sidecar, a saved session on its note. A nil handler hides
/// that control — e.g. a saved session that's still being written is read-only.
struct FeedActions {
    /// Right-click research actions on transcript text (empty hides them).
    var transcriptActions: [TranscriptAction] = []
    /// (card kind, selected text, paragraph) — a research action was chosen.
    var onAction: (String, String, FeedParagraph) -> Void = { _, _, _ in }
    /// (note text, offset within the paragraph, paragraph) — "Add note here…".
    var onAddNote: ((String, Int, FeedParagraph) -> Void)?
    /// A transcription correction was confirmed (issue #32).
    var onCorrect: ((TranscriptCorrectionRequest, FeedParagraph) -> Void)?
    var onToggleCard: ((Card) -> Void)?
    var onDeleteCard: ((Card) -> Void)?
    /// Skip a card that's still researching.
    var onCancelCard: ((Card) -> Void)?
    /// A follow-up typed into a finished card.
    var onReply: ((Card, String) -> Void)?
    /// Delete an editorial note, by its `FeedItem.note` id.
    var onDeleteNote: ((String) -> Void)?
}

/// The conversation as both windows show it: transcript runs with each
/// paragraph's time in the margin, cards, editorial notes and section headings.
/// Its body is a `ForEach`, so the caller's stack (lazy in the recording window)
/// lays the rows out — space them with `FeedView.spacing`, and leave
/// `Theme.Metric.readingMargin` beside the column for the margin times.
struct FeedView: View {
    let items: [FeedItem]
    let actions: FeedActions

    static let spacing: CGFloat = 14

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .transcript(let paragraphs):
                FeedTranscriptRun(paragraphs: paragraphs, actions: actions)
            case .card(let card):
                FeedCardView(card: card, actions: actions)
                    .padding(.vertical, 6)
            case .note(let id, let text):
                FeedNoteView(text: text, onDelete: actions.onDeleteNote.map { delete in { delete(id) } })
                    .padding(.vertical, 6)
            case .heading(_, let title):
                FeedSectionLabel(title: title).padding(.top, 10)
            }
        }
    }
}

/// A grey section label ("Transcript", "You asked", a saved heading), with an
/// optional count beside it.
struct FeedSectionLabel: View {
    let title: String
    var count: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            if let count {
                Text(count).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// A run of transcript between cards, as plain text with each paragraph's time
/// hanging in the left margin. Each paragraph keeps its own selectable text view
/// so right-click actions map back to the paragraph they came from.
private struct FeedTranscriptRun: View {
    let paragraphs: [FeedParagraph]
    let actions: FeedActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(paragraphs) { p in
                SelectableTranscriptText(
                    text: p.text, toolTip: p.toolTip, actions: actions.transcriptActions,
                    onAction: { kind, selection in actions.onAction(kind, selection, p) },
                    onAddNote: actions.onAddNote.map { add in { text, offset in add(text, offset, p) } },
                    onCorrect: actions.onCorrect.map { correct in { request in correct(request, p) } })
                    .overlay(alignment: .topLeading) {
                        if let time = p.time {
                            Text(time).font(.system(size: 11.5)).monospacedDigit()
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize()
                                .offset(x: -Theme.Metric.timeGutter, y: 3)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card in the feed — answer, context, fact-check, summary or saved follow-up:
/// a coloured kind label over its title, then the body, footer (trigger quote or
/// note, and sources) and follow-up field, on a faint fill. Copy and Delete show
/// while the pointer is over the card (`HoverReveal`, so hovering doesn't redraw
/// the text); the collapse chevron also stays visible while collapsed, so a
/// collapsed card shows it can open.
struct FeedCardView: View {
    let card: Card
    let actions: FeedActions
    @State private var hover = HoverState()

    private var isAnswer: Bool { card.kind == "answer" || card.kind == "query" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if card.isExpanded {
                if !card.body.isEmpty && card.body != "…" {
                    MarkdownText(markdown: card.body, style: card.kind == "context" ? .context : .answer)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
                // Summary cards are a one-shot recap, not a conversation, so they
                // don't take follow-ups; nor does a blockquote Advisor didn't write.
                if let onReply = actions.onReply,
                    card.state == "done" && !card.replying && card.kind != "summary" && !card.kind.isEmpty
                {
                    CardReplyField(accent: isAnswer ? Theme.accent : nil) { onReply(card, $0) }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, card.isExpanded ? 20 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceCardSubtle, in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
        .onHover { hover.isOn = $0 }
        // The hover controls are transparent, so out of the accessibility tree,
        // until the pointer is over the card; offer them as actions instead.
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button("Copy", action: copyToClipboard)
            if let toggle = actions.onToggleCard, Self.canCollapse(card) {
                Button(card.isExpanded ? "Collapse" : "Expand") { toggle(card) }
            }
            if let delete = actions.onDeleteCard {
                Button("Delete card") { delete(card) }
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                let kind = Self.kindName(card)
                if !kind.isEmpty {
                    HStack(spacing: 6) {
                        Circle().frame(width: 6, height: 6)
                        Text(kind)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Self.kindColour(card))
                }
                // The summary's label already says Summary; its title would repeat it.
                if card.kind != "summary" && !card.title.isEmpty {
                    Text(card.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Theme.textStrong)
                        .lineLimit(card.isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            status
            HoverReveal(hover: hover) { hovering in
                HStack(spacing: 2) {
                    CardIconButton(system: "doc.on.doc", help: "Copy", action: copyToClipboard)
                        .opacity(hovering ? 1 : 0)
                    if let toggle = actions.onToggleCard, Self.canCollapse(card) {
                        CardIconButton(
                            system: card.isExpanded ? "chevron.up" : "chevron.down",
                            help: card.isExpanded ? "Collapse" : "Expand", action: { toggle(card) })
                            .opacity(hovering || !card.isExpanded ? 1 : 0)
                    }
                    if let delete = actions.onDeleteCard {
                        CardIconButton(system: "xmark", help: "Delete card", action: { delete(card) })
                            .opacity(hovering ? 1 : 0)
                    }
                }
            }
        }
        .font(.system(size: 12.5))
    }

    @ViewBuilder private var status: some View {
        if card.isResearching {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Researching").foregroundStyle(Theme.textTertiary)
                if let cancel = actions.onCancelCard, !card.replying {
                    CardIconButton(system: "xmark.circle.fill", help: "Skip this card", action: { cancel(card) })
                }
            }
        } else if card.state == "failed" {
            Text("failed").foregroundStyle(Theme.factRed)
        } else if card.state == "cancelled" {
            Text("cancelled").foregroundStyle(Theme.textTertiary)
        }
    }

    /// Whether collapsing leaves something to show: a kind label or a title. A
    /// saved blockquote Advisor didn't write has neither, so it stays open.
    static func canCollapse(_ card: Card) -> Bool {
        !kindName(card).isEmpty || !card.title.isEmpty
    }

    /// The label above the title: the kind, or a fact-check's verdict. Empty for
    /// a saved blockquote Advisor didn't write.
    static func kindName(_ card: Card) -> String {
        switch card.kind {
        case "": ""
        case "context": "Context"
        case "summary": "Summary"
        case "question": "Question"
        case "factcheck":
            switch card.verdict {
            case .verified: "Verified"
            case .needsContext: "Needs context"
            case .misleading: "Misleading"
            case nil: "Fact-check"
            }
        default: "Answer"
        }
    }

    static func kindColour(_ card: Card) -> Color {
        switch card.kind {
        case "context": Theme.contextViolet
        case "summary": Theme.summaryTeal
        case "factcheck":
            switch card.verdict {
            case .verified: Theme.factGreen
            case .needsContext: Theme.factAmber
            case .misleading: Theme.factRed
            case nil: Theme.textSecondary
            }
        default: Theme.accent
        }
    }

    // MARK: footer

    @ViewBuilder private var footer: some View {
        let note: String? = card.footnote
            ?? (isAnswer ? SavedCard.groundedNote : card.triggerQuote.map { "↳ “\($0)”" })
        if note != nil || !card.sources.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                if let note {
                    Text(note)
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

    // MARK: copy

    /// Plain-text snapshot of the card for the clipboard: title, body, then any
    /// source links. Available whether the card is collapsed or expanded.
    private var clipboardText: String {
        var parts: [String] = []
        let title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append(title) }
        let body = card.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty && body != "…" { parts.append(body) }
        if !card.sources.isEmpty {
            parts.append(card.sources.map { "\($0.label) — \($0.url)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboardText, forType: .string)
    }
}

/// An editorial note the user injected (issue #34): their own context the audio
/// missed or got wrong, on a green fill with a Note label so it's obvious it
/// isn't transcript. Delete shows on hover when the window allows it.
struct FeedNoteView: View {
    let text: String
    var onDelete: (() -> Void)?
    @State private var hover = HoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().frame(width: 6, height: 6)
                    Text("Note")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.factGreen)
                Spacer(minLength: 8)
                if let onDelete {
                    HoverReveal(hover: hover) { hovering in
                        CardIconButton(system: "xmark", help: "Delete note", action: onDelete)
                            .opacity(hovering ? 1 : 0)
                    }
                }
            }
            MarkdownText(markdown: text, style: .answer)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.factGreenTint.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metric.cardRadius))
        .onHover { hover.isOn = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if let onDelete { Button("Delete note", action: onDelete) }
        }
    }
}

/// Whether the pointer is over a card or note. A reference the card holds but
/// never reads in its own body: only `HoverReveal` reads it, so a pointer
/// crossing cards as the feed scrolls redraws their buttons, not their text.
@MainActor
@Observable
final class HoverState {
    var isOn = false
}

/// Builds `content` from the hover state, read here so hover changes redraw
/// only this.
private struct HoverReveal<Content: View>: View {
    let hover: HoverState
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(hover.isOn) }
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
        .accessibilityLabel(help)
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
                .focusEffectDisabled()
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
