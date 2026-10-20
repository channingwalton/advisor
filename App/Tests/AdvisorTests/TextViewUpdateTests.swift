import AppKit
import Testing

@testable import Advisor

// SwiftUI calls `updateNSView` whenever a row's parent redraws — in the
// recording window, on every live interim-speech update — so a text view must
// only re-render and re-measure when what it shows has changed, or scrolling
// stutters.

@MainActor
@Test func markdownTextRerendersOnlyWhenItsContentChanges() {
    let tv = IntrinsicHeightTextView(frame: .zero)
    #expect(MarkdownText(markdown: "**A** body", style: .answer).apply(to: tv) == true)
    #expect(MarkdownText(markdown: "**A** body", style: .answer).apply(to: tv) == false)
    #expect(MarkdownText(markdown: "**A** body, longer", style: .answer).apply(to: tv) == true)
    #expect(MarkdownText(markdown: "**A** body, longer", style: .context).apply(to: tv) == true)
    #expect(tv.string == "A body, longer")
}

@MainActor
@Test func transcriptTextRestylesOnlyWhenItsTextChanges() {
    let tv = ActionTextView(frame: .zero)
    func view(_ text: String) -> SelectableTranscriptText {
        SelectableTranscriptText(text: text, toolTip: "", actions: [], onAction: { _, _ in })
    }
    #expect(view("Hello there.").apply(to: tv) == true)
    #expect(view("Hello there.").apply(to: tv) == false)
    #expect(view("Hello there. More.").apply(to: tv) == true)
    #expect(tv.string == "Hello there. More.")
    #expect(tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        == NSFont.systemFont(ofSize: Theme.Metric.transcriptSize))
}

@MainActor
@Test func aSkippedTranscriptUpdateStillTakesTheNewHandlers() {
    let tv = ActionTextView(frame: .zero)
    var corrected = ""
    SelectableTranscriptText(text: "Same.", toolTip: "10:00", actions: [], onAction: { _, _ in }).apply(to: tv)
    let skipped = SelectableTranscriptText(
        text: "Same.", toolTip: "10:01", actions: [TranscriptAction(title: "Answer", kind: "answer")],
        onAction: { _, _ in }, onAddNote: { _ in }, onCorrect: { corrected = $0.replacement }
    ).apply(to: tv)

    #expect(skipped == false)
    #expect(tv.toolTip == "10:01")
    #expect(tv.menuActions.map(\.kind) == ["answer"])
    #expect(tv.onAddNote != nil)
    tv.onCorrect?(TranscriptCorrectionRequest(original: "a", replacement: "b", occurrenceInParagraph: 0, scope: .thisOccurrence))
    #expect(corrected == "b")
}
