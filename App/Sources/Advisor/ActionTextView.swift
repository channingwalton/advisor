import AppKit
import SwiftUI

/// One right-click AI action: a menu title and the card kind it requests.
struct TranscriptAction {
    let title: String
    let kind: String

    /// The right-click research actions — the same trigger kinds the
    /// auto-classifier uses, gated by the same Preferences toggles (so a kind
    /// disabled there never appears here either). `kind` is the card kind the
    /// sidecar emits.
    static func research(for triggers: AdvisorConfig.Triggers) -> [TranscriptAction] {
        var actions: [TranscriptAction] = []
        if triggers.question { actions.append(TranscriptAction(title: "Answer", kind: "answer")) }
        if triggers.context { actions.append(TranscriptAction(title: "Context", kind: "context")) }
        if triggers.factcheck { actions.append(TranscriptAction(title: "Fact check", kind: "factcheck")) }
        return actions
    }
}

/// A transcription correction chosen from the right-click menu (issue #32).
/// `occurrenceInParagraph` is the 0-based index of the highlighted span among
/// matches of `original` in the displayed paragraph — used only to pin the exact
/// instance for `.thisOccurrence`; `.allInSession` ignores it.
struct TranscriptCorrectionRequest {
    enum Scope { case thisOccurrence, allInSession }
    let original: String
    let replacement: String
    let occurrenceInParagraph: Int
    let scope: Scope
}

/// Selectable transcript line backed by an NSTextView, so the right-click menu
/// can act on the exact highlighted span (SwiftUI's `Text` selection is opaque
/// to a `.contextMenu`). Falls back to the whole line when nothing is selected.
struct SelectableTranscriptText: NSViewRepresentable {
    let text: String
    let toolTip: String
    let actions: [TranscriptAction]
    /// (card kind, selected text) — fired when an AI action is chosen.
    let onAction: (String, String) -> Void
    /// Fired with the selection-end/click offset within this paragraph when the
    /// user chooses "Add note here…" (issue #34); the window opens its Note
    /// popover placed there (issue #104). Nil hides the menu item — e.g. the
    /// still-being-written live note in the browser.
    var onAddNote: ((Int) -> Void)? = nil
    /// Fired when a correction is confirmed (issue #32). Nil hides the correction
    /// menu items — e.g. the still-being-written live note in the browser.
    var onCorrect: ((TranscriptCorrectionRequest) -> Void)? = nil
    /// The paragraph's lines, which `text` shows joined by single spaces. A
    /// selection across a join can't be corrected (issue #92), so the menu needs
    /// to know where the joins are. Nil: `text` is a single line.
    var lines: [String]? = nil

    func makeNSView(context: Context) -> ActionTextView {
        // Convenience init builds a TextKit stack the view *owns* (storage
        // included) — a hand-built stack would leave storage/layoutManager
        // unretained and they'd deallocate. Touching `layoutManager` forces the
        // TextKit 1 fallback so it's available for height measurement (TextKit 2
        // leaves it nil).
        let tv = ActionTextView(frame: .zero)
        _ = tv.layoutManager
        // Height is reported through the view's own intrinsicContentSize (see
        // ActionTextView), recomputed for whatever width SwiftUI lays it out at.
        // The container width tracks the frame, so the measured height can never
        // diverge from the drawn wrap width — a custom sizeThatFits could commit a
        // height from a probe wider than the final draw, clipping wrapped lines on
        // session switch (issue #12).
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.backgroundColor = NSColor.clear
        tv.textContainerInset = NSSize.zero
        // Populate content here too, not only in updateNSView: when a session is
        // selected the whole detail VStack is built at once, so the first height
        // read must already see the real text.
        apply(to: tv)
        return tv
    }

    func updateNSView(_ tv: ActionTextView, context: Context) {
        apply(to: tv)
    }

    /// Push the current text + styling into the view's storage. isRichText is
    /// false, so style the storage directly — typingAttributes alone won't
    /// reflow already-set text, and height measurement reads the storage's
    /// paragraph style. The text is restyled and re-measured only when it has
    /// changed (`renderedContent`); returns whether it was.
    @discardableResult
    func apply(to tv: ActionTextView) -> Bool {
        // The handlers capture the caller's current state, so always take them —
        // they're cheap to assign. Setting a tool-tip re-registers it with AppKit,
        // so only when it changes.
        if tv.toolTip != toolTip { tv.toolTip = toolTip }
        tv.menuActions = actions
        tv.onAction = onAction
        tv.onAddNote = onAddNote
        tv.onCorrect = onCorrect
        tv.lines = lines ?? [text]
        guard tv.renderedContent != AnyHashable(text) else { return false }
        tv.renderedContent = AnyHashable(text)

        if tv.string != text { tv.string = text }
        // Transcript body type: 14.5 pt, line-height 1.2, semantic body colour.
        let font = NSFont.systemFont(ofSize: Theme.Metric.transcriptSize)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = Theme.Metric.transcriptLineSpacing
        tv.font = font
        tv.textColor = Theme.nsTextBody
        tv.defaultParagraphStyle = para
        let range = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.addAttributes(
            [.font: font, .foregroundColor: Theme.nsTextBody, .paragraphStyle: para], range: range)
        // New text at the same width still changes the line count.
        tv.invalidateIntrinsicContentSize()
        return true
    }
}

/// NSTextView that swaps the default editing context menu for transcript AI
/// actions and copy — all operating on the current selection (or the whole
/// line when nothing is highlighted).
final class ActionTextView: IntrinsicHeightTextView {
    var menuActions: [TranscriptAction] = []
    var onAction: ((String, String) -> Void)?
    var onAddNote: ((Int) -> Void)?
    var onCorrect: ((TranscriptCorrectionRequest) -> Void)?
    /// The lines `string` shows joined by single spaces (`SelectableTranscriptText.lines`).
    var lines: [String] = []
    /// Where an "Add note here…" should anchor: the end of the current selection,
    /// or — with no selection — the character nearest the right-click point.
    /// Captured when the menu opens (issue #34).
    private var noteAnchorOffset = 0

    // Intrinsic-height / width-tracking machinery is shared via
    // IntrinsicHeightTextView (issue #12).

    /// Highlighted substring, or the whole line when the selection is empty.
    private var effectiveSelection: String {
        let range = selectedRange()
        let ns = string as NSString
        return range.length > 0 ? ns.substring(with: range) : string
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // Anchor a note at the selection's end, or — nothing selected — the
        // character nearest the click, so it lands right at the text in view.
        let range = selectedRange()
        noteAnchorOffset = range.length > 0
            ? range.location + range.length
            : characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let selection = effectiveSelection
        let label = selection.count > 40 ? String(selection.prefix(40)) + "…" : selection
        for action in menuActions {
            let item = NSMenuItem(
                title: "\(action.title): “\(label)”",
                action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.kind
            menu.addItem(item)
        }
        if !menuActions.isEmpty { menu.addItem(.separator()) }

        // Add an editorial note here (issue #34): always available where wired,
        // with no selection needed — it anchors to this line.
        if onAddNote != nil {
            let note = NSMenuItem(
                title: "Add note here…", action: #selector(addNoteHere(_:)), keyEquivalent: "")
            note.target = self
            menu.addItem(note)
            menu.addItem(.separator())
        }

        // Correction (issue #32): only on a real highlight, and only where a
        // handler is wired (live feed + saved non-live notes). A highlight across
        // a line join lies in no one line, so neither scope can correct it
        // (issue #92): say so, disabled, rather than offer it. One that overlaps
        // an earlier copy of itself (the second `aa` of `aaa`, the middle `the the`
        // of `the the the the`) can't be corrected on its own either: the count is
        // of non-overlapping matches, so the match its index names isn't the
        // highlight — it may be a later one the edit would rewrite instead, or
        // none at all. "Replace all" takes no index and changes it with the rest,
        // so it stays.
        if onCorrect != nil, let selected = selectedCorrection() {
            let match = TranscriptCorrection.range(ofOccurrence: selected.occurrence, of: selected.original, in: string)
            if match?.location != selected.start {
                let overlaps = NSMenuItem(
                    title: "Can't correct “\(label)” — it overlaps an earlier “\(label)”", action: nil,
                    keyEquivalent: "")
                overlaps.isEnabled = false
                menu.addItem(overlaps)
                menu.addItem(replaceAllItem(label))
            } else if TranscriptCorrection.location(ofOccurrence: selected.occurrence, of: selected.original, in: lines) == nil {
                let spans = NSMenuItem(
                    title: "Can't correct “\(label)” — it spans two lines", action: nil, keyEquivalent: "")
                spans.isEnabled = false
                menu.addItem(spans)
            } else {
                let correct = NSMenuItem(
                    title: "Correct “\(label)”…", action: #selector(correctThisOccurrence(_:)),
                    keyEquivalent: "")
                correct.target = self
                menu.addItem(correct)
                menu.addItem(replaceAllItem(label))
            }
            menu.addItem(.separator())
        }

        let copy = NSMenuItem(title: "Copy", action: #selector(copyText(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    private func replaceAllItem(_ label: String) -> NSMenuItem {
        let all = NSMenuItem(
            title: "Replace all “\(label)”…", action: #selector(correctAllOccurrences(_:)), keyEquivalent: "")
        all.target = self
        return all
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        let selection = effectiveSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return }
        onAction?(kind, selection)
    }

    @objc private func addNoteHere(_ sender: NSMenuItem) {
        onAddNote?(noteAnchorOffset)
    }

    @objc private func correctThisOccurrence(_ sender: NSMenuItem) {
        beginCorrection(scope: .thisOccurrence)
    }

    @objc private func correctAllOccurrences(_ sender: NSMenuItem) {
        beginCorrection(scope: .allInSession)
    }

    /// The highlighted span as the text to correct: trimmed of surrounding
    /// whitespace, with its paragraph-local occurrence index taken from where the
    /// trimmed text starts (`start`, UTF-16) — so the same word selected twice
    /// still pins the right instance. Nil with no highlight, or only whitespace
    /// highlighted.
    private func selectedCorrection() -> (original: String, occurrence: Int, start: Int)? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        let raw = (string as NSString).substring(with: range)
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return nil }
        // Where the trimmed text starts within the highlight, whatever whitespace
        // was trimmed (the trim set, not a list of its own).
        let start = range.location + (raw as NSString).range(of: original).location
        let occurrence = TranscriptCorrection.occurrenceIndex(of: original, before: start, in: string)
        return (original, occurrence, start)
    }

    /// Resolve the highlighted span to a correction request and prompt for the
    /// replacement.
    private func beginCorrection(scope: TranscriptCorrectionRequest.Scope) {
        guard let (original, occurrence, _) = selectedCorrection() else { return }
        guard let replacement = promptForReplacement(of: original), replacement != original
        else { return }
        onCorrect?(
            TranscriptCorrectionRequest(
                original: original, replacement: replacement,
                occurrenceInParagraph: occurrence, scope: scope))
    }

    /// Modal text prompt prefilled with the word being corrected. Nil on cancel.
    private func promptForReplacement(of original: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Correct transcription"
        alert.informativeText = "Replace “\(original)” with:"
        let field = NSTextField(string: original)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Correct")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(effectiveSelection, forType: .string)
    }
}
