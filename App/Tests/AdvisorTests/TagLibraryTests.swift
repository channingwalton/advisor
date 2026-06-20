import Foundation
import Testing

@testable import Advisor

@Test func tagUpsertingUnknownIdAppends() {
    let result = TagLibrary.upserting([], SavedTag(name: "Urgent", colorHex: "0xC0392B"))
    #expect(result.count == 1)
    #expect(result[0].name == "Urgent")
    #expect(result[0].colorHex == "0xC0392B")
}

@Test func tagUpsertingTrimsName() {
    let result = TagLibrary.upserting([], SavedTag(name: "  Work \n", colorHex: "0x3A5CE0"))
    #expect(result[0].name == "Work")
}

@Test func tagUpsertingNormalisesSeparatorCharactersInName() {
    // Commas/newlines (the frontmatter tag separators) are squashed to spaces, so
    // the stored library name matches the form a note round-trips back to.
    let result = TagLibrary.upserting([], SavedTag(name: "Q1,Q2", colorHex: "0x3A5CE0"))
    #expect(result[0].name == "Q1 Q2")
}

@Test func tagWithSeparatorInNameStillResolvesAfterRoundTrip() {
    // The original Codex finding: a comma'd tag applied to a session must still
    // resolve its colour. Library name == frontmatter form, so `named` matches.
    let tag = TagLibrary.upserting([], SavedTag(name: "Q1,Q2", colorHex: "0x3A5CE0"))[0]
    let written = SessionArchive.tagsLine([tag.name])          // → the note
    let parsed = SessionArchive.parseTags(written)             // ← from the note
    #expect(TagLibrary.named(parsed[0], in: [tag])?.colorHex == "0x3A5CE0")
}

@Test func tagUpsertingBlankNameIsIgnored() {
    let existing = [SavedTag(name: "A", colorHex: "0x3A5CE0")]
    #expect(TagLibrary.upserting(existing, SavedTag(name: " ", colorHex: "0xC0392B")) == existing)
}

@Test func tagUpsertingKnownIdReplacesInPlaceAllowingRenameAndRecolour() {
    let id = UUID()
    let existing = [
        SavedTag(id: id, name: "Old", colorHex: "0x3A5CE0"),
        SavedTag(name: "Other", colorHex: "0x2F8D5B"),
    ]
    let result = TagLibrary.upserting(existing, SavedTag(id: id, name: "New", colorHex: "0xC0392B"))
    #expect(result.count == 2) // replaced, not appended
    #expect(result[0].id == id)
    #expect(result[0].name == "New")
    #expect(result[0].colorHex == "0xC0392B")
}

@Test func tagUpsertingDuplicateNameOnDifferentIdIsRejected() {
    let existing = [SavedTag(name: "Work", colorHex: "0x3A5CE0")]
    // A new tag (different id) whose name collides case-insensitively is dropped.
    let result = TagLibrary.upserting(existing, SavedTag(name: "work", colorHex: "0xC0392B"))
    #expect(result == existing)
}

@Test func tagRemovingDropsTheMatchingId() {
    let keep = SavedTag(name: "keep", colorHex: "0x3A5CE0")
    let drop = SavedTag(name: "drop", colorHex: "0xC0392B")
    #expect(TagLibrary.removing([keep, drop], id: drop.id) == [keep])
}

@Test func tagRemovingUnknownIdIsNoOp() {
    let only = [SavedTag(name: "only", colorHex: "0x3A5CE0")]
    #expect(TagLibrary.removing(only, id: UUID()) == only)
}

@Test func tagNamedMatchesCaseInsensitivelyAndTrimmed() {
    let tags = [SavedTag(name: "Work", colorHex: "0x3A5CE0")]
    #expect(TagLibrary.named(" work ", in: tags)?.colorHex == "0x3A5CE0")
    #expect(TagLibrary.named("missing", in: tags) == nil)
}

@Test func suggestionsExcludeAppliedCaseInsensitively() {
    let library = [
        SavedTag(name: "Work", colorHex: "0x3A5CE0"),
        SavedTag(name: "Urgent", colorHex: "0xC0392B"),
    ]
    let result = TagLibrary.suggestions(library, applied: ["work"])
    #expect(result.map(\.name) == ["Urgent"])
}

@Test func suggestionsPreserveLibraryOrder() {
    let library = [
        SavedTag(name: "B", colorHex: "0x3A5CE0"),
        SavedTag(name: "A", colorHex: "0xC0392B"),
    ]
    #expect(TagLibrary.suggestions(library, applied: []).map(\.name) == ["B", "A"])
}

@Test func configDecodesMissingTagsAsEmpty() throws {
    let json = Data("{}".utf8)
    let config = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(config.tags.isEmpty)
}

@Test func configRoundTripsTags() throws {
    var config = AdvisorConfig()
    config.tags = [SavedTag(name: "Work", colorHex: "0x3A5CE0")]
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AdvisorConfig.self, from: data)
    #expect(decoded.tags == config.tags)
}
