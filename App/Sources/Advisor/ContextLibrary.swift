import Foundation

/// A reusable, named session context (issue #10). The library is App-side only
/// data — persisted in config.json alongside the other App-only fields, never
/// seen by the sidecar (which only receives the resolved context text per
/// session).
struct SavedContext: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var text: String

    init(id: UUID = UUID(), name: String, text: String) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// Pure operations over the saved-context list, so the add/save/delete logic is
/// testable independently of the SwiftUI views that drive it.
enum ContextLibrary {
    /// Insert or replace a context. A blank (whitespace-only) name is ignored —
    /// the list is returned unchanged. Otherwise, if a context already exists
    /// with the same trimmed, case-insensitive name, its text is replaced in
    /// place (id preserved); else a new entry is appended. The stored name is
    /// the trimmed form.
    static func saving(_ contexts: [SavedContext], name: String, text: String) -> [SavedContext] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contexts }
        var result = contexts
        if let i = result.firstIndex(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            result[i].name = trimmed
            result[i].text = text
        } else {
            result.append(SavedContext(name: trimmed, text: text))
        }
        return result
    }

    /// Insert or replace a context by id — the Preferences editor's commit. An
    /// existing id is updated in place (so a rename is allowed without spawning a
    /// duplicate); an unknown id is appended. A blank name leaves the list
    /// unchanged. The stored name is trimmed.
    static func upserting(_ contexts: [SavedContext], _ draft: SavedContext) -> [SavedContext] {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return contexts }
        let entry = SavedContext(id: draft.id, name: trimmed, text: draft.text)
        var result = contexts
        if let i = result.firstIndex(where: { $0.id == draft.id }) {
            result[i] = entry
        } else {
            result.append(entry)
        }
        return result
    }

    /// Remove the context with the given id (no-op if absent).
    static func removing(_ contexts: [SavedContext], id: UUID) -> [SavedContext] {
        contexts.filter { $0.id != id }
    }
}
