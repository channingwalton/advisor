import Foundation
import Testing

@testable import Advisor

@Test func parseTagsSplitsTrimsAndDropsEmpties() {
    #expect(SessionArchive.parseTags("work,  urgent ,, follow-up") == ["work", "urgent", "follow-up"])
    #expect(SessionArchive.parseTags("") == [])
    #expect(SessionArchive.parseTags("   ") == [])
}

@Test func tagsLineSanitisesDedupesAndKeepsOrder() {
    // Commas/newlines inside a name (the separators) squash to spaces; the
    // case-insensitive duplicate is dropped; first occurrence keeps its order.
    let line = SessionArchive.tagsLine(["Work", " urgent ", "work", "a,b\nc"])
    #expect(line == "Work, urgent, a b c")
}

@Test func tagsLineRoundTripsThroughParse() {
    let tags = ["Work", "Follow-up", "Q3 review"]
    #expect(SessionArchive.parseTags(SessionArchive.tagsLine(tags)) == tags)
}

@Test func settingTagsInsertsAndPreservesEverythingElse() {
    let note = "---\nname: Talk\nstarted: 2026-06-18T17:00:00Z\ncontext: Effects\n---\n\n"
        + "# Transcript\n\n- 17:00:00 hi\n"
    let out = SessionArchive.settingTags(["work", "urgent"], in: note)
    #expect(SessionArchive.frontmatter(out)["tags"] == "work, urgent")
    #expect(SessionArchive.frontmatter(out)["name"] == "Talk")      // other keys kept
    #expect(SessionArchive.frontmatter(out)["context"] == "Effects")
    #expect(out.contains("- 17:00:00 hi"))                          // body kept
}

@Test func settingTagsReplacesExisting() {
    let note = "---\ntags: old\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n"
    let out = SessionArchive.settingTags(["new"], in: note)
    #expect(SessionArchive.frontmatter(out)["tags"] == "new")
    #expect(!out.contains("tags: old"))
}

@Test func settingEmptyTagsRemovesKey() {
    let note = "---\ntags: work\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n"
    let out = SessionArchive.settingTags([], in: note)
    #expect(SessionArchive.frontmatter(out)["tags"] == nil)
    #expect(SessionArchive.frontmatter(out)["started"] == "2026-06-18T17:00:00Z")
}

@Test func settingTagsAddsFrontmatterWhenAbsent() {
    let note = "# Transcript\n\n- 17:00 hi\n"
    let out = SessionArchive.settingTags(["work"], in: note)
    #expect(out.hasPrefix("---\ntags: work\n---\n\n"))
    #expect(SessionArchive.strippingFrontmatter(out) == note)       // body untouched
}

@Test func sessionDetailParsesTags() {
    let note = "---\nstarted: 2026-06-18T17:00:00Z\ntags: work, urgent\n---\n\n# Transcript\n\n- 17:00:00 hi"
    let d = SessionDetail.parse(contents: note, fallbackTitle: "x")
    #expect(d.tags == ["work", "urgent"])
}

@Test func sessionDetailHasNoTagsWhenAbsent() {
    let note = "---\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n\n- 17:00:00 hi"
    #expect(SessionDetail.parse(contents: note, fallbackTitle: "x").tags == [])
}

@Test func inlineWritesTagsToFrontmatter() {
    let md = SessionMarkdown.inline(
        utterances: [], cards: [], started: Date(timeIntervalSince1970: 0), ended: nil,
        tags: ["work", "work", "urgent"])
    #expect(md.contains("tags: work, urgent\n"))   // deduped
}

@Test func inlineOmitsTagsLineWhenEmpty() {
    let md = SessionMarkdown.inline(
        utterances: [], cards: [], started: Date(timeIntervalSince1970: 0), ended: nil)
    #expect(!md.contains("tags:"))
}

@Test func renamingTagReplacesMatchingNameCaseInsensitively() {
    let note = "---\nstarted: 2026-06-18T17:00:00Z\ntags: work, urgent\n---\n\n# Transcript\n"
    let out = SessionArchive.renamingTag(from: "WORK", to: "Project X", in: note)
    #expect(SessionArchive.parseTags(SessionArchive.frontmatter(out)["tags"]!) == ["Project X", "urgent"])
}

@Test func renamingTagLeavesNoteWithoutTheTagUnchanged() {
    let note = "---\nstarted: 2026-06-18T17:00:00Z\ntags: urgent\n---\n\n# Transcript\n"
    #expect(SessionArchive.renamingTag(from: "work", to: "x", in: note) == note)
}

@Test func renamingTagMergesWhenTargetAlreadyPresent() {
    let note = "---\ntags: work, urgent\nstarted: 2026-06-18T17:00:00Z\n---\n\n# Transcript\n"
    // Renaming "work" → "urgent" de-dups to a single tag.
    let out = SessionArchive.renamingTag(from: "work", to: "urgent", in: note)
    #expect(SessionArchive.parseTags(SessionArchive.frontmatter(out)["tags"]!) == ["urgent"])
}

@Test func renameTagAcrossNotesRewritesOnlyAffectedAndSkipsExcluded() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-rename-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let tagged = dir.appendingPathComponent("2026-06-18-100000.md")
    let other = dir.appendingPathComponent("2026-06-18-110000.md")
    let live = dir.appendingPathComponent("2026-06-18-120000.md")
    try "---\ntags: work\n---\n\n# Transcript\n".write(to: tagged, atomically: true, encoding: .utf8)
    try "---\ntags: misc\n---\n\n# Transcript\n".write(to: other, atomically: true, encoding: .utf8)
    try "---\ntags: work\n---\n\n# Transcript\n".write(to: live, atomically: true, encoding: .utf8)

    let changed = SessionArchive.renameTag(from: "work", to: "Project X", in: dir, excluding: live)
    #expect(changed == 1) // only `tagged`; `other` lacks it, `live` is skipped

    func tags(_ url: URL) -> [String] {
        SessionArchive.parseTags(SessionArchive.frontmatter(
            (try? String(contentsOf: url, encoding: .utf8)) ?? "")["tags"] ?? "")
    }
    #expect(tags(tagged) == ["Project X"])
    #expect(tags(other) == ["misc"])
    #expect(tags(live) == ["work"]) // untouched (renamed via its writer instead)
}

@Test func renameTagUpdatesFolderDefaults() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-tags-rename-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderTags(["work", "urgent"], for: "Team", root: dir))

    #expect(SessionArchive.renameTag(from: "WORK", to: "Project X", in: dir) == 0)
    #expect(SessionArchive.folderTags("Team", root: dir) == ["Project X", "urgent"])
}

@Test func removingLibraryTagClearsItFromFolderDefaults() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-folder-tags-delete-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(SessionArchive.setFolderTags(["work", "urgent"], for: "Team", root: dir))
    #expect(SessionArchive.setFolderTags(["WORK"], for: "Solo", root: dir))

    #expect(SessionArchive.removeTagFromFolderDefaults("Work", in: dir) == 2)
    #expect(SessionArchive.folderTags("Team", root: dir) == ["urgent"])
    #expect(SessionArchive.folderTags("Solo", root: dir).isEmpty)
    let soloURL = try #require(SessionArchive.folderTagsURL("Solo", root: dir))
    #expect(!FileManager.default.fileExists(atPath: soloURL.path))
}

@Test func setTagsRoundTripsThroughDisk() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-tags-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("2026-06-18-170000.md")
    try "---\ncontext: Effects\n---\n\n# Transcript\n\n- 17:00:00 hi\n"
        .write(to: url, atomically: true, encoding: .utf8)

    let file = try #require(SessionArchive.list(in: dir).first)
    #expect(SessionArchive.setTags(["work", "urgent"], in: file))

    let parsed = SessionDetail.parse(
        contents: SessionArchive.contents(of: file), fallbackTitle: "x")
    #expect(parsed.tags == ["work", "urgent"])
    #expect(parsed.context == "Effects")   // untouched
}
