import Foundation
import Testing

@testable import Advisor

/// `renameSession` (SessionActions) against the three states a note can be in:
/// live and owned by the writer, live but unowned (issue #85), and saved.
/// Serialised because the routing reads the process-wide
/// `TranscriptWindowContext.shared`.
@MainActor
@Suite(.serialized)
struct SessionRenameTests {
    private static let markdown =
        "---\ncontext: Effects\nname: Original\n---\n\n# Transcript\n\n- 17:00:00 hi\n"

    private func savedNote() throws -> (file: SessionFile, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-rename-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("2026-06-18-170000.md")
        try Self.markdown.write(to: url, atomically: true, encoding: .utf8)
        return (try #require(SessionArchive.list(in: dir).first), dir)
    }

    private func nameOnDisk(_ url: URL) throws -> String? {
        SessionArchive.frontmatter(try String(contentsOf: url, encoding: .utf8))["name"]
    }

    /// Set the shared context for one test and restore it afterwards.
    private func withContext(
        live: URL?, writer: SessionWriter?, _ body: (TranscriptWindowContext) -> Void
    ) {
        let ctx = TranscriptWindowContext.shared
        let (oldLive, oldWriter) = (ctx.liveFileURL, ctx.writer)
        defer { (ctx.liveFileURL, ctx.writer) = (oldLive, oldWriter) }
        (ctx.liveFileURL, ctx.writer) = (live, writer)
        body(ctx)
    }

    // Issue #85: the live note with no writer to route through must not be
    // edited on disk — the writer's next rewrite would clobber the edit, so the
    // rename would silently vanish. Refuse it instead.
    @Test func liveNoteWithoutWriterIsLeftAlone() throws {
        let (file, dir) = try savedNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        withContext(live: file.url, writer: nil) { ctx in
            renameSession(file, to: "Renamed", ctx: ctx)
        }
        #expect(try nameOnDisk(file.url) == "Original")
    }

    @Test func liveNoteIsRenamedThroughItsWriter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("advisor-rename-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = SessionWriter(store: TranscriptStore(), resolveDirectory: { root })
        writer.start(name: "Original")
        let url = try #require(writer.currentFileURL)
        // Built from the writer's URL, as the browser's row is in the archive under
        // `$HOME`; `list(in:)` under the temp dir would resolve `/var` to
        // `/private/var` and the raw-URL comparison the routing makes would miss.
        let file = SessionFile(
            url: url, date: try #require(SessionArchive.date(from: url.lastPathComponent)),
            folder: nil)
        withContext(live: url, writer: writer) { ctx in
            renameSession(file, to: "Renamed", ctx: ctx)
        }
        #expect(try nameOnDisk(url) == "Renamed")
        // The writer carries the name, so its own later rewrite keeps it.
        writer.flush()
        #expect(try nameOnDisk(url) == "Renamed")
        writer.releaseNote()
    }

    @Test func savedNoteIsRenamedOnDisk() throws {
        let (file, dir) = try savedNote()
        defer { try? FileManager.default.removeItem(at: dir) }
        withContext(live: nil, writer: nil) { ctx in
            renameSession(file, to: "Renamed", ctx: ctx)
        }
        #expect(try nameOnDisk(file.url) == "Renamed")
    }
}
