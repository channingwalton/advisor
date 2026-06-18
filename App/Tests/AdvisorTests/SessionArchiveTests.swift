import Testing
import Foundation

@testable import Advisor

@Test func parsesSessionFilenameDate() {
    #expect(SessionArchive.date(from: "2026-06-18-163953.md") != nil)
    // Non-session names are rejected.
    #expect(SessionArchive.date(from: "notes.md") == nil)
    #expect(SessionArchive.date(from: "README.md") == nil)
    // Right shape, wrong extension.
    #expect(SessionArchive.date(from: "2026-06-18-163953.txt") == nil)
    // Impossible components are rejected (non-lenient parsing).
    #expect(SessionArchive.date(from: "2026-13-99-999999.md") == nil)
}

@Test func filenameDateRoundTrips() throws {
    let name = "2026-06-18-163953.md"
    let date = try #require(SessionArchive.date(from: name))
    // Re-deriving the name from the parsed date reproduces the original.
    #expect(SessionArchive.fileName(for: date) == name)
}

@Test func listsValidSessionsNewestFirst() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    for name in ["2026-06-18-090000.md", "2026-06-18-170000.md", "notes.txt", "README.md"] {
        try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    let files = SessionArchive.list(in: dir)

    // Only the two well-formed session notes; notes.txt and README.md are skipped.
    #expect(files.count == 2)
    #expect(files.first?.url.lastPathComponent == "2026-06-18-170000.md") // newest first
    #expect(files.last?.url.lastPathComponent == "2026-06-18-090000.md")
}

@Test func stripsLeadingYamlFrontmatter() {
    let note = "---\nstarted: 2026-06-18T15:39:53Z\nended: 2026-06-18T15:42:24Z\n---\n\n"
        + "# Transcript\n\n- 16:40:05 hello\n"
    let body = SessionArchive.strippingFrontmatter(note)
    // The metadata block is gone (so markdown can't misread `key:`+`---` as a
    // giant setext heading) and the body starts at the transcript.
    #expect(!body.contains("started:"))
    #expect(!body.contains("ended:"))
    #expect(body.hasPrefix("# Transcript"))
    #expect(body.contains("- 16:40:05 hello"))
}

@Test func leavesContentWithoutFrontmatterUnchanged() {
    let note = "# Transcript\n\n- 16:40 hi\n"
    #expect(SessionArchive.strippingFrontmatter(note) == note)
}

@Test func readsContentsOfSessionFile() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-archive-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("2026-06-18-170000.md")
    try "# Transcript\n\n- 17:00:00 hello\n".write(to: url, atomically: true, encoding: .utf8)

    let file = try #require(SessionArchive.list(in: dir).first)
    #expect(SessionArchive.contents(of: file).contains("hello"))
}
