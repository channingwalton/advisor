import AppKit
import SwiftUI
import Testing

@testable import Advisor

private struct Toolbar: View {
    let ask: String
    let note: String
    let store = TranscriptStore()

    var body: some View {
        ListeningToolbar(
            store: store, recordingState: .idle, sessionStart: nil, stoppedAt: nil, targetFolder: nil,
            selectedDevice: .constant(nil), devices: [], captureSystem: true, sessionName: .constant(""),
            sessionContext: .constant(""), sessionTags: .constant([]), savedContexts: [], tagLibrary: [],
            onSaveContext: { _ in }, autoCards: .constant(true), hideTranscript: .constant(false),
            pinned: .constant(false), onStart: {}, onResume: {}, onMuteToggle: {}, onStop: {}, canExport: false,
            onExport: {}, canSummarise: false, onSummarise: {}, askText: .constant(ask), showAsk: .constant(false),
            onAsk: {}, noteDraft: .constant(NoteDraft(text: note)), showNote: .constant(false), onNote: {})
    }
}

/// A draft waiting in a closed popover shows a dot on its button without
/// widening it (issue #104): a wider toolbar could tip it into its compact
/// layout as the first key is typed, and the open popover would lose its
/// button and close.
@MainActor
@Test func aWaitingDraftDoesNotWidenTheToolbar() {
    func width(ask: String, note: String) -> CGFloat {
        NSHostingView(rootView: Toolbar(ask: ask, note: note)).fittingSize.width
    }
    #expect(width(ask: "x", note: "x") == width(ask: "", note: ""))
}

/// Hide transcript, Summarise, Float and Export fold into a More menu when the
/// window is too narrow for every button, so the toolbar fits a narrower window
/// than the ~700pt it needed once Ask and Note joined it.
@MainActor
@Test func aNarrowToolbarFoldsItsLessUsedButtonsIntoMore() {
    let width: CGFloat = 650
    let fitted = NSHostingController(rootView: Toolbar(ask: "", note: ""))
        .sizeThatFits(in: CGSize(width: width, height: Theme.Metric.toolbarHeight)).width
    #expect(fitted <= width)
}

/// Narrowing the window only ever takes controls away: the less-used buttons
/// fold into More while the labels stay, then the labels go, and nothing
/// unfolds on the way.
@Test func theToolbarFoldsItsLessUsedButtonsBeforeDroppingLabels() {
    let layouts = ListeningToolbar.Layout.narrowing
    #expect(layouts.first == .init(compact: false, folded: false))
    #expect(layouts.last == .init(compact: true, folded: true))
    #expect(layouts.contains(.init(compact: false, folded: true)))
    for (wider, narrower) in zip(layouts, layouts.dropFirst()) {
        #expect(!wider.compact || narrower.compact)
        #expect(!wider.folded || narrower.folded)
    }
}
