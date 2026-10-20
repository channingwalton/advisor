import Foundation

/// Where a note opened from "Add note here…" goes (issue #104): the character
/// the click or selection ended at within a feed paragraph. Each window maps it
/// to its own line — an utterance live, a transcript line saved.
struct NotePlacement: Equatable {
    let offset: Int
    let paragraph: FeedParagraph

    /// The transcript line the note goes under, as the Note popover quotes it.
    var line: String {
        let texts = paragraph.lines.map(\.text)
        return NoteAnchor.lineIndex(forOffset: offset, in: texts).map { texts[$0] } ?? paragraph.text
    }
}

/// The Note popover's draft (issue #104), kept between openings so a click away
/// doesn't lose it: the text typed so far and, when it was opened from "Add note
/// here…", the line it goes under. No placement: the end of the transcript.
struct NoteDraft: Equatable {
    var text = ""
    var placement: NotePlacement?

    /// Whether there's no text to add — what greys out the submit button and
    /// hides the toolbar's draft dot.
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Hand the trimmed text and placement to `add`, and start a fresh draft once
    /// it has taken the note: one that couldn't be saved stays, to try again.
    /// False, without calling `add`, when there's no text.
    @discardableResult
    mutating func submit(to add: (String, NotePlacement?) -> Bool) -> Bool {
        guard !isBlank, add(text.trimmingCharacters(in: .whitespacesAndNewlines), placement) else { return false }
        self = NoteDraft()
        return true
    }
}
