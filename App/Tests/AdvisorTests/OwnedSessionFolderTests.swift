import Foundation
import Testing

@testable import Advisor

@MainActor
@Test func req_folder_owned_preserved() throws {
    // Stop leaves writer ownership intact; both listening states must protect
    // both mutations and preserve writes made after the attempted move.
    for listening in [true, false] {
        for deleting in [false, true] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("advisor-owned-folder-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TranscriptStore()
            store.listening = listening
            let writer = SessionWriter(store: store, resolveDirectory: { root })
            writer.start(folder: "Work")
            let ownedURL = try #require(writer.currentFileURL)

            let moved = deleting
                ? SessionArchive.deleteFolder("Work", in: root, excluding: writer.currentFileURL)
                : SessionArchive.renameFolder(
                    from: "Work", to: "Projects", in: root, excluding: writer.currentFileURL)
            #expect(!moved)
            store.utterances.append(Utterance(
                time: Date(), source: .me, text: "After the attempted folder change", latencyMs: 0))
            store.cards.append(Card(
                id: "last-card", created: Date(), kind: "answer", title: "Saved answer",
                body: "Card after the attempted folder change", state: "done", triggerId: nil,
                triggerQuote: nil, sources: [], verdict: nil))
            writer.end()
            writer.releaseNote()

            let contents = try String(contentsOf: ownedURL, encoding: .utf8)
            #expect(contents.contains("After the attempted folder change"))
            #expect(contents.contains("Card after the attempted folder change"))
            #expect(!store.status.contains("not saved"))
        }
    }
}

@MainActor
@Test func req_folder_owned_released() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-released-folder-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { root })
    writer.start(folder: "Work")
    #expect(SessionArchive.createFolder("Workshops", in: root))
    #expect(SessionArchive.renameFolder(
        from: "Workshops", to: "Other", in: root, excluding: writer.currentFileURL))
    #expect(SessionArchive.deleteFolder("Other", in: root, excluding: writer.currentFileURL))
    writer.end()
    writer.releaseNote()
    #expect(SessionArchive.renameFolder(
        from: "Work", to: "Projects", in: root, excluding: writer.currentFileURL))
    #expect(SessionArchive.deleteFolder("Projects", in: root, excluding: writer.currentFileURL))
    #expect(SessionArchive.list(in: root).count == 1)
}
