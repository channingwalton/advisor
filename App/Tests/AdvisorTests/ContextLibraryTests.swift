import Foundation
import Testing

@testable import Advisor

@Test func savingIntoEmptyAppendsOne() {
    let result = ContextLibrary.saving([], name: "Standup", text: "daily")
    #expect(result.count == 1)
    #expect(result[0].name == "Standup")
    #expect(result[0].text == "daily")
}

@Test func savingTrimsTheName() {
    let result = ContextLibrary.saving([], name: "  Board review \n", text: "x")
    #expect(result[0].name == "Board review")
}

@Test func savingBlankNameIsIgnored() {
    let existing = [SavedContext(name: "A", text: "1")]
    #expect(ContextLibrary.saving(existing, name: "   ", text: "anything") == existing)
}

@Test func savingExistingNameReplacesTextAndKeepsId() {
    let id = UUID()
    let existing = [SavedContext(id: id, name: "Interview", text: "old")]
    let result = ContextLibrary.saving(existing, name: "interview", text: "new")
    #expect(result.count == 1)
    #expect(result[0].id == id) // same entry, updated in place
    #expect(result[0].name == "interview") // stored as the trimmed input name
    #expect(result[0].text == "new")
}

@Test func upsertingUnknownIdAppends() {
    let result = ContextLibrary.upserting([], SavedContext(name: "New", text: "t"))
    #expect(result.count == 1)
    #expect(result[0].name == "New")
}

@Test func upsertingKnownIdReplacesInPlaceAllowingRename() {
    let id = UUID()
    let existing = [
        SavedContext(id: id, name: "Old name", text: "old"),
        SavedContext(name: "Other", text: "x"),
    ]
    let result = ContextLibrary.upserting(
        existing, SavedContext(id: id, name: "New name", text: "new"))
    #expect(result.count == 2) // replaced, not appended
    #expect(result[0].id == id)
    #expect(result[0].name == "New name")
    #expect(result[0].text == "new")
}

@Test func upsertingBlankNameIsIgnored() {
    let existing = [SavedContext(name: "A", text: "1")]
    #expect(ContextLibrary.upserting(existing, SavedContext(name: " ", text: "y")) == existing)
}

@Test func removingDropsTheMatchingId() {
    let keep = SavedContext(name: "keep", text: "1")
    let drop = SavedContext(name: "drop", text: "2")
    let result = ContextLibrary.removing([keep, drop], id: drop.id)
    #expect(result == [keep])
}

@Test func removingUnknownIdIsNoOp() {
    let only = [SavedContext(name: "only", text: "1")]
    #expect(ContextLibrary.removing(only, id: UUID()) == only)
}

@Test func configDecodesMissingContextsAsEmpty() throws {
    let json = Data("{}".utf8)
    let config = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(config.contexts.isEmpty)
}

@Test func configRoundTripsContexts() throws {
    var config = AdvisorConfig()
    config.contexts = [SavedContext(name: "One", text: "first")]
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AdvisorConfig.self, from: data)
    #expect(decoded.contexts == config.contexts)
}
