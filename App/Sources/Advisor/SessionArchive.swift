import Foundation

/// A saved session note on disk: the file and its start time, parsed from the
/// `yyyy-MM-dd-HHmmss.md` filename `SessionWriter` assigns.
struct SessionFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
}

/// Reads back the session notes `SessionWriter` saves, for browsing past
/// transcripts. Owns the on-disk location and filename convention (the live
/// writer delegates to it), so the format lives in one place.
enum SessionArchive {
    /// Where session notes are stored — `~/Library/Application Support/Advisor/sessions`.
    static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor/sessions", isDirectory: true)
    }

    /// `yyyy-MM-dd-HHmmss` with calendar/locale pinned, so a session filename is
    /// always Gregorian regardless of the user's system calendar. Used to both
    /// format new names and parse existing ones.
    static let fileNameFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        fmt.isLenient = false
        return fmt
    }()

    /// The note filename for a session that started at `date`.
    static func fileName(for date: Date) -> String {
        "\(fileNameFormatter.string(from: date)).md"
    }

    /// Parses a session note name (`yyyy-MM-dd-HHmmss.md`) to its start time.
    /// Nil for any name not in that exact, non-lenient Gregorian form.
    static func date(from filename: String) -> Date? {
        guard filename.hasSuffix(".md") else { return nil }
        return fileNameFormatter.date(from: String(filename.dropLast(3)))
    }

    /// Session notes in `directory`, newest first; non-session files are skipped.
    static func list(in directory: URL = SessionArchive.directory) -> [SessionFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .compactMap { url -> SessionFile? in
                date(from: url.lastPathComponent).map { SessionFile(url: url, date: $0) }
            }
            .sorted { $0.date > $1.date }
    }

    /// The note's raw markdown, or "" if it can't be read.
    static func contents(of file: SessionFile) -> String {
        (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
    }

    /// Parses the leading `---` … `---` frontmatter into `key: value` pairs
    /// (the format `SessionMarkdown.inline` writes: `started`, `ended`,
    /// `context`). Empty when there's no frontmatter block.
    static func frontmatter(_ markdown: String) -> [String: String] {
        guard markdown.hasPrefix("---\n") else { return [:] }
        let afterOpen = markdown.index(markdown.startIndex, offsetBy: 4)
        guard let close = markdown.range(of: "\n---\n", range: afterOpen..<markdown.endIndex)
        else { return [:] }
        var out: [String: String] = [:]
        for line in markdown[afterOpen..<close.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// The note body with any leading YAML frontmatter (`---` … `---`) removed,
    /// for display. Without this, markdown reads the `started:`/`ended:` lines
    /// closed by `---` as a setext heading and renders them huge. The session
    /// date is shown separately, so dropping the block loses nothing.
    static func strippingFrontmatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n") else { return markdown }
        let afterOpen = markdown.index(markdown.startIndex, offsetBy: 4)
        guard let close = markdown.range(of: "\n---\n", range: afterOpen..<markdown.endIndex)
        else { return markdown }
        return String(markdown[close.upperBound...].drop(while: { $0 == "\n" }))
    }

    /// `markdown` with a single scalar frontmatter `key:` set to `value` (collapsed
    /// to one line). An empty/blank `value` removes the key. Existing frontmatter
    /// keys and the body are preserved; a note without frontmatter gains one. Pure,
    /// for testability. The shared core behind `settingName`/`settingTags`.
    static func settingScalar(_ key: String, _ value: String, in markdown: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard markdown.hasPrefix("---\n"),
            let close = markdown.range(
                of: "\n---\n",
                range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex)
        else {
            // No frontmatter: prepend one carrying just this key (nothing to do
            // when clearing a key that was never set).
            return trimmed.isEmpty ? markdown : "---\n\(key): \(trimmed)\n---\n\n" + markdown
        }
        let open = markdown.index(markdown.startIndex, offsetBy: 4)
        var lines = markdown[open..<close.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.hasPrefix("\(key):") }
        if !trimmed.isEmpty { lines.append("\(key): \(trimmed)") }
        return "---\n" + lines.joined(separator: "\n") + markdown[close.lowerBound...]
    }

    /// `markdown` with its `name:` frontmatter set to `name`. An empty/blank `name`
    /// removes the key. Used to rename a *saved* session — the live note is renamed
    /// through `SessionWriter` instead, to avoid the two-writer clobber.
    static func settingName(_ name: String, in markdown: String) -> String {
        settingScalar("name", name, in: markdown)
    }

    /// Set (or clear) the `name:` frontmatter of `file` on disk. Returns false if
    /// the write fails.
    @discardableResult
    static func setName(_ name: String, in file: SessionFile) -> Bool {
        let updated = settingName(name, in: contents(of: file))
        do {
            try updated.write(to: file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Parse a `tags:` frontmatter value (comma-separated) into names: trimmed,
    /// empties dropped, order preserved. The inverse of `tagsLine`.
    static func parseTags(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The canonical form of a single tag name: trimmed, with the `tags:` line
    /// separators (commas, newlines) squashed to spaces. The tag library stores
    /// names in this form too, so a name written to a note round-trips back to the
    /// same string `TagLibrary.named` resolves a colour by.
    static func normalisedTagName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// The canonical `tags:` frontmatter value for `tags`: each name normalised,
    /// empties dropped, and case-insensitive duplicates removed (first occurrence
    /// wins, order kept). "" when there are no usable tags. The single source of
    /// truth for the tag line, shared by `settingTags` and `SessionMarkdown.inline`.
    static func tagsLine(_ tags: [String]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags {
            let name = normalisedTagName(tag)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out.joined(separator: ", ")
    }

    /// `markdown` with its `tags:` frontmatter set to `tags`. An empty list removes
    /// the key. Used to tag a *saved* session — the live note is tagged through
    /// `SessionWriter` instead, to avoid the two-writer clobber.
    static func settingTags(_ tags: [String], in markdown: String) -> String {
        settingScalar("tags", tagsLine(tags), in: markdown)
    }

    /// Set (or clear) the `tags:` frontmatter of `file` on disk. Returns false if
    /// the write fails.
    @discardableResult
    static func setTags(_ tags: [String], in file: SessionFile) -> Bool {
        let updated = settingTags(tags, in: contents(of: file))
        do {
            try updated.write(to: file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// `markdown` with any `old` tag in its frontmatter renamed to `new`
    /// (case-insensitive match). Unchanged when the note doesn't carry the tag.
    /// `settingTags` re-de-dups, so renaming onto a tag the note already has
    /// merges them. Pure, for testability. Backs the Preferences rename that
    /// propagates a tag's new name across every note already tagged with it.
    static func renamingTag(from old: String, to new: String, in markdown: String) -> String {
        let oldTrim = old.trimmingCharacters(in: .whitespaces)
        let tags = parseTags(frontmatter(markdown)["tags"] ?? "")
        guard tags.contains(where: { $0.caseInsensitiveCompare(oldTrim) == .orderedSame })
        else { return markdown }
        let renamed = tags.map {
            $0.caseInsensitiveCompare(oldTrim) == .orderedSame ? new : $0
        }
        return settingTags(renamed, in: markdown)
    }

    /// Rename a tag from `old` to `new` across every saved note in `directory`,
    /// skipping `excluding` (the live note, which is rewritten through its writer
    /// instead). Returns the number of notes changed. Notes without the tag are
    /// untouched. Synchronous file I/O — fine for a personal archive of this size.
    @discardableResult
    static func renameTag(
        from old: String, to new: String,
        in directory: URL = SessionArchive.directory, excluding: URL? = nil
    ) -> Int {
        var changed = 0
        for file in list(in: directory) {
            if let excluding,
                file.url.standardizedFileURL == excluding.standardizedFileURL { continue }
            let original = contents(of: file)
            let updated = renamingTag(from: old, to: new, in: original)
            if updated != original,
                (try? updated.write(to: file.url, atomically: true, encoding: .utf8)) != nil {
                changed += 1
            }
        }
        return changed
    }

    /// Delete `file` from disk. Returns false if removal fails (e.g. the note is
    /// already gone). Irreversible — the caller owns confirmation.
    @discardableResult
    static func delete(_ file: SessionFile) -> Bool {
        do {
            try FileManager.default.removeItem(at: file.url)
            return true
        } catch {
            return false
        }
    }

    /// `existing` with a follow-up Q&A appended under a single `# Follow-ups`
    /// heading (added the first time only). Pure, for testability.
    static func appendingFollowUp(
        to existing: String, question: String, answer: String, asked: Date
    ) -> String {
        var out = existing
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if out.range(of: "\n# Follow-ups") == nil && !out.hasPrefix("# Follow-ups") {
            out += "\n# Follow-ups\n"
        }
        out += "\n" + SessionMarkdown.followUpBlock(
            question: question, answer: answer, asked: asked) + "\n"
        return out
    }

    /// Append a follow-up Q&A to `file` on disk. Returns false if the write fails.
    @discardableResult
    static func appendFollowUp(
        question: String, answer: String, to file: SessionFile, asked: Date = Date()
    ) -> Bool {
        let updated = appendingFollowUp(
            to: contents(of: file), question: question, answer: answer, asked: asked)
        do {
            try updated.write(to: file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
