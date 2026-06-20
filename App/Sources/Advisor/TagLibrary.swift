import Foundation

/// A user-defined session tag (issue #15): a name plus a colour, managed in
/// Preferences. The library is App-side only data — persisted in config.json
/// alongside the other App-only fields (like `contexts`), never seen by the
/// sidecar. A session references tags by *name* in its note frontmatter; the
/// colour is resolved by looking the name up in this library, so a tag deleted
/// here simply stops rendering on session cards.
struct SavedTag: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// A `0xRRGGBB` swatch from `Theme.tagSwatches`, stored as text so it
    /// round-trips through JSON. Resolved to a colour at render time.
    var colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

/// Pure operations over the tag library, so add/edit/delete logic is testable
/// independently of the SwiftUI views that drive it. Tag names are the key a
/// session references, so they are kept unique (trimmed, case-insensitive).
enum TagLibrary {
    /// Insert or replace a tag by id — the Preferences editor's commit. An
    /// existing id is updated in place (so a rename or recolour is allowed
    /// without spawning a duplicate); an unknown id is appended. A blank name,
    /// or a name that collides (case-insensitively) with a *different* tag, is
    /// rejected and the list returned unchanged. The stored name is trimmed.
    static func upserting(_ tags: [SavedTag], _ draft: SavedTag) -> [SavedTag] {
        // Store the name in the same canonical form it takes in a note's
        // frontmatter, so a tag whose name contains a comma still resolves its
        // colour after being applied (the frontmatter squashes commas to spaces).
        let trimmed = SessionArchive.normalisedTagName(draft.name)
        guard !trimmed.isEmpty else { return tags }
        let collides = tags.contains {
            $0.id != draft.id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !collides else { return tags }
        let entry = SavedTag(id: draft.id, name: trimmed, colorHex: draft.colorHex)
        var result = tags
        if let i = result.firstIndex(where: { $0.id == draft.id }) {
            result[i] = entry
        } else {
            result.append(entry)
        }
        return result
    }

    /// Remove the tag with the given id (no-op if absent).
    static func removing(_ tags: [SavedTag], id: UUID) -> [SavedTag] {
        tags.filter { $0.id != id }
    }

    /// The tag whose name matches `name` (trimmed, case-insensitive), or nil.
    /// Used to resolve a session tag's colour from its frontmatter name.
    static func named(_ name: String, in tags: [SavedTag]) -> SavedTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return tags.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Library tags not yet applied to a session (names compared case-insensitively),
    /// in library order. Drives the session tag pick-list (issue #15).
    static func suggestions(_ tags: [SavedTag], applied: [String]) -> [SavedTag] {
        let appliedSet = Set(applied.map { $0.lowercased() })
        return tags.filter { !appliedSet.contains($0.name.lowercased()) }
    }
}
