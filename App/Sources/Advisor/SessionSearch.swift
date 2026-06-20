import Foundation

/// Matching for the Sessions browser search box. Kept pure so the query syntax is
/// testable apart from the view.
enum SessionSearch {
    /// Does `session` (its frontmatter `tags` and its lowercased `haystack`) match
    /// `query`? A `#tag` token filters by tag — the session must carry a tag whose
    /// name *contains* the term, so `#foo` matches the tag, not a transcript word
    /// "foo". Plain words match the haystack as one substring (the prior
    /// behaviour). Multiple `#tag` tokens must all match (AND). An empty query
    /// matches everything (issue #15).
    static func matches(query: String, tags: [String], haystack: String) -> Bool {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return true }

        var tagTerms: [String] = []
        var textTerms: [String] = []
        for token in tokens {
            if token.hasPrefix("#"), token.count > 1 {
                tagTerms.append(String(token.dropFirst()))
            } else if token != "#" {
                textTerms.append(token)
            }
        }

        let lowerTags = tags.map { $0.lowercased() }
        for term in tagTerms where !lowerTags.contains(where: { $0.contains(term) }) {
            return false
        }
        if !textTerms.isEmpty, !haystack.contains(textTerms.joined(separator: " ")) {
            return false
        }
        return true
    }
}
