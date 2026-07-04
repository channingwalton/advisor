import Foundation

/// A saved session note on disk: the file and its start time, parsed from the
/// `yyyy-MM-dd-HHmmss.md` filename `SessionWriter` assigns. `folder` is the name
/// of the immediate sub-directory the note lives in (issue #25), or `nil` when it
/// sits directly in the archive root (un-foldered).
struct SessionFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let date: Date
    var folder: String?
}

/// Reads back the session notes `SessionWriter` saves, for browsing past
/// transcripts. Owns the on-disk location and filename convention (the live
/// writer delegates to it), so the format lives in one place.
enum SessionArchive {
    /// The built-in location used when no custom folder is configured —
    /// `~/Library/Application Support/Advisor/sessions`.
    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Advisor/sessions", isDirectory: true)
    }

    /// Resolve a configured `sessionDir` (issue #16) to a directory URL: the
    /// `defaultDirectory` when blank, else that absolute path. Pure, for
    /// testability — `directory` feeds it the live config value.
    static func directory(for sessionDir: String) -> URL {
        let trimmed = sessionDir.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty
            ? defaultDirectory : URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Where session notes are stored: the folder chosen in Preferences
    /// (`AdvisorConfig.sessionDir`) or the built-in default. Read fresh from
    /// config so a folder change applies without an app relaunch.
    static var directory: URL { directory(for: AdvisorConfig.load().sessionDir) }

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
    /// Descends one level into sub-directories (issue #25): a note in `<dir>/Work`
    /// is returned with `folder == "Work"`, a note directly in `dir` with `folder
    /// == nil`. Only one level is scanned — deeper nesting and dot-directories are
    /// ignored.
    static func list(in directory: URL = SessionArchive.directory) -> [SessionFile] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var files: [SessionFile] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let folder = entry.lastPathComponent
                guard !folder.hasPrefix(".") else { continue }
                let inner = (try? fm.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil)) ?? []
                for url in inner {
                    if let date = date(from: url.lastPathComponent) {
                        files.append(SessionFile(url: url, date: date, folder: folder))
                    }
                }
            } else if let date = date(from: entry.lastPathComponent) {
                files.append(SessionFile(url: entry, date: date, folder: nil))
            }
        }
        return files.sorted { $0.date > $1.date }
    }

    /// The folder names in `directory` (issue #25): every immediate sub-directory,
    /// dot-directories excluded, case-insensitively sorted. Empty folders are
    /// included — the folder list is derived from disk, so an empty folder simply
    /// persists as an empty directory (no separate config registry, unlike tags).
    static func folders(in directory: URL = SessionArchive.directory) -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .compactMap { entry -> String? in
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let name = entry.lastPathComponent
                return (isDir && !name.hasPrefix(".")) ? name : nil
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// A folder name reduced to a safe single path component, or `nil` if unusable.
    /// Trims, then rejects empty, dot-leading (hidden / `.`/`..`), and names
    /// carrying a path separator (`/`) or HFS separator (`:`). The single gate
    /// behind `createFolder`/`renameFolder`/`setFolder`.
    static func sanitiseFolderName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."),
            !trimmed.contains("/"), !trimmed.contains(":") else { return nil }
        return trimmed
    }

    /// The note's raw markdown, or `nil` if the file can't be read — missing,
    /// unreadable, or vanished under us. Distinct from a genuinely empty note,
    /// which reads as "". Read-modify-write setters use this to abort rather than
    /// clobber a note that isn't there (issue #41); display uses `contents(of:)`.
    static func readContents(of file: SessionFile) -> String? {
        try? String(contentsOf: file.url, encoding: .utf8)
    }

    /// The note's raw markdown, or "" if it can't be read. For display and
    /// derivation, where an empty fallback is harmless; mutating setters use
    /// `readContents` so they can tell a missing note from an empty one.
    static func contents(of file: SessionFile) -> String {
        readContents(of: file) ?? ""
    }

    /// Read `file`, transform its markdown, and atomically write it back — the
    /// shared spine of the read-modify-write setters. Aborts (returns false) when
    /// the note can't be read (issue #41: never recreate a vanished or unreadable
    /// note as a stub, losing the transcript) or the write fails. `transform` sees
    /// the note's real contents, never "".
    private static func rewrite(_ file: SessionFile, _ transform: (String) -> String) -> Bool {
        guard let existing = readContents(of: file) else { return false }
        let updated = transform(existing)
        // An atomic write recreates a file deleted since the read, so re-check
        // just before replacing — don't resurrect a note removed mid-edit.
        guard FileManager.default.fileExists(atPath: file.url.path) else { return false }
        do {
            try updated.write(to: file.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
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
    /// the note can't be read (issue #41) or the write fails.
    @discardableResult
    static func setName(_ name: String, in file: SessionFile) -> Bool {
        rewrite(file) { settingName(name, in: $0) }
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
    /// the note can't be read (issue #41) or the write fails.
    @discardableResult
    static func setTags(_ tags: [String], in file: SessionFile) -> Bool {
        rewrite(file) { settingTags(tags, in: $0) }
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

    /// Move every session note from `source` to `dest`, creating `dest` if
    /// needed (issue #16: relocating transcripts when the storage folder
    /// changes). Skips the `excluding` note (the live one, still owned by its
    /// writer) and any note whose name already exists in `dest` (never clobbers).
    /// Non-session files are ignored — `list` only yields well-formed notes.
    /// Returns how many moved and how many were skipped on collision. Synchronous
    /// file I/O — fine for a personal archive of this size, like `renameTag`.
    @discardableResult
    static func move(from source: URL, to dest: URL, excluding: URL? = nil) -> (moved: Int, skipped: Int) {
        guard source.standardizedFileURL != dest.standardizedFileURL else { return (0, 0) }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var moved = 0, skipped = 0
        for file in list(in: source) {
            if let excluding,
                file.url.standardizedFileURL == excluding.standardizedFileURL { continue }
            // Preserve folder structure (issue #25): a note in `source/Work` lands
            // in `dest/Work`, an un-foldered note directly in `dest`.
            let targetDir = file.folder.map {
                dest.appendingPathComponent($0, isDirectory: true)
            } ?? dest
            let target = targetDir.appendingPathComponent(file.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { skipped += 1; continue }
            try? FileManager.default.createDirectory(
                at: targetDir, withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: file.url, to: target)) != nil {
                moved += 1
            } else {
                skipped += 1
            }
        }
        // Carry each folder's context file (issue #36): `list` doesn't surface the
        // hidden file, so move it explicitly, or a storage-dir change would strand
        // folder contexts. Never clobbers a context already at the destination.
        for folder in folders(in: source) {
            guard let src = folderContextURL(folder, root: source),
                let dst = folderContextURL(folder, root: dest),
                FileManager.default.fileExists(atPath: src.path),
                !FileManager.default.fileExists(atPath: dst.path) else { continue }
            try? FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: src, to: dst)
        }
        return (moved, skipped)
    }

    /// Create folder `name` under `directory` (issue #25). Returns false for an
    /// unusable name (`sanitiseFolderName`) or a failed `createDirectory`.
    /// Idempotent: creating a folder that already exists succeeds.
    @discardableResult
    static func createFolder(_ name: String, in directory: URL = SessionArchive.directory) -> Bool {
        guard let folder = sanitiseFolderName(name) else { return false }
        let url = directory.appendingPathComponent(folder, isDirectory: true)
        return (try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)) != nil
    }

    /// The hidden file holding a folder's context (issue #36):
    /// `<root>/<folder>/.context.md`. `nil` for an unusable folder name. Dot-prefixed
    /// and not a session-date name, so `list`/`folders` ignore it (a file, not a
    /// directory), and it travels with the directory on `renameFolder`.
    static func folderContextURL(_ folder: String, root: URL = SessionArchive.directory) -> URL? {
        guard let safe = sanitiseFolderName(folder) else { return nil }
        return root.appendingPathComponent(safe, isDirectory: true)
            .appendingPathComponent(".context.md")
    }

    /// A folder's saved context (issue #36), or "" when none is set or the name is
    /// unusable. Surrounding whitespace is trimmed so it round-trips the editor text.
    static func folderContext(_ folder: String, root: URL = SessionArchive.directory) -> String {
        guard let url = folderContextURL(folder, root: root),
            let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Set (or clear) a folder's context (issue #36). A blank `text` removes the
    /// file (no empty `.context.md` litter). Creates the folder directory if needed,
    /// so context can be set before the folder holds any session. Returns false for
    /// an unusable name or a failed write/remove.
    @discardableResult
    static func setFolderContext(
        _ text: String, for folder: String, root: URL = SessionArchive.directory
    ) -> Bool {
        guard let url = folderContextURL(folder, root: root) else { return false }
        let fm = FileManager.default
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard fm.fileExists(atPath: url.path) else { return true }
            return (try? fm.removeItem(at: url)) != nil
        }
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// File `file` into `folder` (issue #25) by moving the note on disk: into
    /// `<root>/<folder>/` when set, back to `<root>` when `nil`. Creates the folder
    /// directory if needed. Never clobbers an existing note at the destination
    /// (returns `nil`); returns `file` unchanged if it is already there. Returns the
    /// relocated `SessionFile` (new URL + folder) on success, `nil` on an invalid
    /// folder name or a failed move. Saved-note counterpart to the live note's
    /// exclusion — the owned note is filed through the recording window, not here.
    static func setFolder(
        _ folder: String?, for file: SessionFile, root: URL = SessionArchive.directory
    ) -> SessionFile? {
        let fm = FileManager.default
        let folderName: String?
        if let folder {
            guard let safe = sanitiseFolderName(folder) else { return nil }
            folderName = safe
        } else {
            folderName = nil
        }
        // Un-filing the last note leaves its source folder behind empty by design:
        // empty folders persist (see `folders`), so the folder doesn't vanish from
        // the sidebar just because its final session moved out.
        let targetDir = folderName.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        let dest = targetDir.appendingPathComponent(file.url.lastPathComponent)
        if dest.standardizedFileURL == file.url.standardizedFileURL {
            return SessionFile(url: file.url, date: file.date, folder: folderName)
        }
        if fm.fileExists(atPath: dest.path) { return nil }
        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            try fm.moveItem(at: file.url, to: dest)
            return SessionFile(url: dest, date: file.date, folder: folderName)
        } catch {
            return nil
        }
    }

    /// Rename folder `old` to `new` under `directory` (issue #25) by moving the
    /// directory — its notes travel with it. Returns false for an unusable `new`
    /// name, a missing source, or a collision with a *different* existing folder. A
    /// case-only rename (`work` → `Work`) on a case-insensitive volume is allowed.
    @discardableResult
    static func renameFolder(
        from old: String, to new: String, in directory: URL = SessionArchive.directory
    ) -> Bool {
        guard let newName = sanitiseFolderName(new),
            let oldName = sanitiseFolderName(old) else { return false }
        let fm = FileManager.default
        let src = directory.appendingPathComponent(oldName, isDirectory: true)
        let dst = directory.appendingPathComponent(newName, isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return false }
        if src.standardizedFileURL == dst.standardizedFileURL { return true }
        // Block only a collision with a genuinely different folder; a case-only
        // rename resolves to the same path case-insensitively and must go through.
        let sameNameCaseInsensitive = src.standardizedFileURL.path
            .compare(dst.standardizedFileURL.path, options: .caseInsensitive) == .orderedSame
        if !sameNameCaseInsensitive, fm.fileExists(atPath: dst.path) { return false }
        return (try? fm.moveItem(at: src, to: dst)) != nil
    }

    /// Delete folder `name` (issue #25) without deleting its sessions: each note is
    /// un-filed back to `directory` (collisions skipped), then the directory is
    /// removed only if nothing remains in it — so unknown non-session files there
    /// are never destroyed. Returns true when the directory was removed.
    @discardableResult
    static func deleteFolder(_ name: String, in directory: URL = SessionArchive.directory) -> Bool {
        guard let safe = sanitiseFolderName(name) else { return false }
        let fm = FileManager.default
        let folderURL = directory.appendingPathComponent(safe, isDirectory: true)
        for file in list(in: folderURL) {
            let dest = directory.appendingPathComponent(file.url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { continue }
            try? fm.moveItem(at: file.url, to: dest)
        }
        // Our own folder-context file (issue #36) shouldn't block removal, but it
        // must not be destroyed if the delete is aborted: ignore it when checking
        // emptiness, and only remove it once everything else is gone (a same-named
        // note that couldn't un-file keeps the folder — and its context — intact).
        let ctx = folderContextURL(safe, root: directory)
        let remaining = ((try? fm.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.standardizedFileURL != ctx?.standardizedFileURL }
        guard remaining.isEmpty else { return false }
        if let ctx, fm.fileExists(atPath: ctx.path) { try? fm.removeItem(at: ctx) }
        return (try? fm.removeItem(at: folderURL)) != nil
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

    /// `existing` with its `# Summary` section set to `summary` (issue #30):
    /// replaces the section in place when one is present, else inserts it just
    /// before `# Transcript` (matching the byte layout `SessionMarkdown.inline`
    /// writes, so the live and saved surfaces share one location). Pure, for
    /// testability. `summary` is the plain body; it's wrapped as a card block.
    static func upsertingSummary(into existing: String, summary: String) -> String {
        let sectionLines =
            ["# Summary", ""] + SessionMarkdown.summaryBlock(summary).components(separatedBy: "\n") + [""]
        var lines = existing.components(separatedBy: "\n")

        if let start = lines.firstIndex(of: "# Summary") {
            // The section runs to the next top-level heading (`# Transcript` /
            // `# Follow-ups`) or end-of-file; quoted body lines start with ">",
            // never "# ", so they can't terminate it early.
            var end = start + 1
            while end < lines.count && !lines[end].hasPrefix("# ") { end += 1 }
            lines.replaceSubrange(start..<end, with: sectionLines)
        } else if let transcript = lines.firstIndex(of: "# Transcript") {
            lines.insert(contentsOf: sectionLines, at: transcript)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(contentsOf: sectionLines)
        }
        return lines.joined(separator: "\n")
    }

    /// Add or update the `# Summary` section of `file` on disk (issue #30).
    /// Returns false if the note can't be read (issue #41) or the write fails.
    @discardableResult
    static func upsertSummary(_ summary: String, to file: SessionFile) -> Bool {
        rewrite(file) { upsertingSummary(into: $0, summary: summary) }
    }

    /// Append a follow-up Q&A to `file` on disk. Returns false if the note can't
    /// be read (issue #41) or the write fails.
    @discardableResult
    static func appendFollowUp(
        question: String, answer: String, to file: SessionFile, asked: Date = Date()
    ) -> Bool {
        rewrite(file) {
            appendingFollowUp(to: $0, question: question, answer: answer, asked: asked)
        }
    }

    /// Correct a transcription error in a saved note (issue #32): replace the
    /// `occurrence`-th match of `original` within the transcript paragraph at
    /// `paragraphIndex` (counting only paragraph blocks) with `replacement`, then
    /// write the note back. Frontmatter and cards are left untouched. Returns false
    /// if nothing changed or the write fails. Saved-note only — the live note is
    /// corrected through its `TranscriptStore` instead, to avoid the writer clobber.
    @discardableResult
    static func correctOccurrence(
        _ occurrence: Int, of original: String, with replacement: String,
        inParagraph paragraphIndex: Int, of file: SessionFile
    ) -> Bool {
        let existing = contents(of: file)
        let updated = TranscriptCorrection.replacingOccurrence(
            occurrence, of: original, with: replacement,
            inParagraph: paragraphIndex, ofMarkdown: existing)
        guard updated != existing else { return false }
        return (try? updated.write(to: file.url, atomically: true, encoding: .utf8)) != nil
    }

    /// Correct every occurrence of `original` in a saved note's transcript with
    /// `replacement` (issue #32). Only the transcript utterance lines change —
    /// frontmatter, cards, and follow-ups are left byte-identical. Returns false if
    /// nothing changed or the write fails.
    @discardableResult
    static func correctAll(
        of original: String, with replacement: String, in file: SessionFile
    ) -> Bool {
        let existing = contents(of: file)
        let updated = TranscriptCorrection.replacingAllInTranscript(
            of: original, with: replacement, inMarkdown: existing)
        guard updated != existing else { return false }
        return (try? updated.write(to: file.url, atomically: true, encoding: .utf8)) != nil
    }
}
