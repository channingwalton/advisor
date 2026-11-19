import Foundation

/// A saved session note on disk: the file and its start time, parsed from the
/// `yyyy-MM-dd-HHmmss.md` filename `SessionWriter` assigns. `folder` is the path
/// of the folder the note lives in, relative to the archive root, such as `Work`
/// (issue #25) or `Work/Client A` (issue #155), or `nil` when it sits directly in
/// the archive root (un-foldered).
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
    /// The folder for `sessionDir` as Preferences wrote it (an absolute path) or
    /// as a hand edit of config.json might: a `~` is the home folder; a relative
    /// path, which would resolve against the app's working directory (`/` when
    /// packaged) and fail every save, falls back to the default.
    static func directory(for sessionDir: String) -> URL {
        let trimmed = (sessionDir.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        return trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed, isDirectory: true) : defaultDirectory
    }

    /// Where session notes are stored: the folder chosen in Preferences
    /// (`AdvisorConfig.sessionDir`) or the built-in default. Read fresh from
    /// config so a folder change applies without an app relaunch. Resolved
    /// (`resolvedFolder`), so a URL built from it, such as the writer's note or
    /// a note filed into a folder, equals the URL that `list` gives for that
    /// note (issue #114).
    static var directory: URL { resolvedFolder(directory(for: AdvisorConfig.load().sessionDir)) }

    /// `url` as `contentsOfDirectory` names a folder: every symlink resolved by
    /// `realpath`, so `/var` reads as `/private/var` (issue #114).
    /// `resolvingSymlinksInPath` drops that `/private`, so it does not match a
    /// listed URL. `realpath` fails on a folder that does not exist, so the
    /// longest part of the path that exists is resolved, and the missing names
    /// follow it. The writer resolves the session folder before it creates it,
    /// so its note then has the URL that `list` gives once the folder exists.
    static func resolvedFolder(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                return missing.reversed().reduce(URL(fileURLWithPath: String(cString: real), isDirectory: true)) {
                    $0.appendingPathComponent($1, isDirectory: true)
                }
            }
            // `realpath` always resolves "/", so this stops there at the latest.
            guard existing.pathComponents.count > 1 else { return url.standardizedFileURL }
            missing.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
    }

    /// True when `a` and `b` are one folder on disk, also by two paths through
    /// a symlink (issue #114).
    static func isSameFolder(_ a: URL, _ b: URL) -> Bool {
        resolvedFolder(a).path == resolvedFolder(b).path
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

    /// The session notes and the folders in `directory`, at every depth
    /// (issue #155). A note directly in `directory` has no folder; a note in
    /// `<dir>/Work/Client A` has the folder `Work/Client A`. Dot-directories and
    /// packages (an app or a Keynote file, which Finder shows as one file) and
    /// what they hold are skipped, and a symlink inside the archive is not
    /// followed, so the walk cannot loop. The folder is resolved first:
    /// `contentsOfDirectory` fails with "Not a directory" when the folder itself
    /// is a symlink (issue #114).
    private static func walk(_ directory: URL) -> (notes: [SessionFile], folders: [String]) {
        let fm = FileManager.default
        var notes: [SessionFile] = []
        var folders: [String] = []
        func visit(_ url: URL, _ folder: String?) {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
            let entries = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys))) ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                let values = try? entry.resourceValues(forKeys: keys)
                if values?.isDirectory ?? false {
                    guard !name.hasPrefix("."), !(values?.isPackage ?? false) else { continue }
                    let path = folder.map { "\($0)/\(name)" } ?? name
                    folders.append(path)
                    visit(entry, path)
                } else if let date = date(from: name) {
                    notes.append(SessionFile(url: entry, date: date, folder: folder))
                }
            }
        }
        visit(resolvedFolder(directory), nil)
        return (notes, folders)
    }

    /// `list` and `folders` from one walk, for a caller that needs both, such as
    /// the Sessions browser's reload.
    static func scan(_ directory: URL = SessionArchive.directory) -> (notes: [SessionFile], folders: [String]) {
        let found = walk(directory)
        return (found.notes.sorted { $0.date > $1.date }, found.folders.sorted(by: folderOrder))
    }

    /// Session notes in `directory`, newest first; non-session files are skipped.
    /// Each note carries the path of its folder (`walk`), at any depth.
    static func list(in directory: URL = SessionArchive.directory) -> [SessionFile] {
        scan(directory).notes
    }

    /// The folder paths in `directory` (issues #25, #155): every sub-directory at
    /// every depth, dot-directories excluded. Sorted name by name,
    /// case-insensitively, so each folder comes just before its subfolders. Empty
    /// folders are included — the folder list is derived from disk, so an empty
    /// folder simply persists as an empty directory (no separate config registry,
    /// unlike tags).
    static func folders(in directory: URL = SessionArchive.directory) -> [String] {
        scan(directory).folders
    }

    /// Tree order for folder paths: compare name by name, so `Work/Client A`
    /// sorts after `Work` and before `Workshop`. Two names that differ only in
    /// case (on a case-sensitive volume) are two folders, so their subfolders
    /// must not mix: such names are ordered by their exact text.
    static func folderOrder(_ a: String, _ b: String) -> Bool {
        let (x, y) = (a.split(separator: "/"), b.split(separator: "/"))
        for (p, q) in zip(x, y) where p != q {
            let order = String(p).localizedCaseInsensitiveCompare(String(q))
            return order == .orderedSame ? p < q : order == .orderedAscending
        }
        return x.count < y.count
    }

    /// A folder name reduced to a safe single path component, or `nil` if unusable.
    /// Trims, then rejects empty, dot-leading (hidden / `.`/`..`), and names
    /// carrying a path separator (`/`) or HFS separator (`:`). The gate for a
    /// name that the user types (`createFolder`, `renameFolder`), and for each
    /// name in a folder path (`sanitiseFolderPath`).
    static func sanitiseFolderName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."),
            !trimmed.contains("/"), !trimmed.contains(":") else { return nil }
        return trimmed
    }

    /// A folder path (issue #155), such as `Work/Client A`, unchanged, or `nil`
    /// when a name in it is blank (`Work//A`, a leading or trailing `/`, spaces
    /// only) or starts with a dot (`..`, a hidden folder), so a path cannot
    /// leave the archive. A
    /// path names folders that exist (it comes from `folders`), so each name is
    /// taken exactly as it is on disk: `Work ` names `Work `, not `Work`, and a
    /// `:` (Finder's `/`) is kept. The gate behind every function that takes a
    /// folder; a name that the user types goes through `sanitiseFolderName`.
    static func sanitiseFolderPath(_ path: String) -> String? {
        let names = path.split(separator: "/", omittingEmptySubsequences: false)
        guard names.allSatisfy({ !$0.allSatisfy(\.isWhitespace) && !$0.hasPrefix(".") }) else { return nil }
        return path
    }

    /// The folder that holds `folder`, or `nil` for a top-level folder.
    static func parentFolder(_ folder: String) -> String? {
        guard let slash = folder.lastIndex(of: "/") else { return nil }
        return String(folder[..<slash])
    }

    /// The last name in a folder path: `Client A` for `Work/Client A`.
    static func folderName(_ folder: String) -> String {
        folder.split(separator: "/").last.map(String.init) ?? folder
    }

    /// How many folders hold `folder`: 0 for a top-level folder.
    static func folderDepth(_ folder: String) -> Int {
        folder.filter { $0 == "/" }.count
    }

    /// True when `folder` is a subfolder of `ancestor` at any depth (not
    /// `ancestor` itself).
    static func isFolder(_ folder: String, inside ancestor: String) -> Bool {
        folder.hasPrefix(ancestor + "/")
    }

    /// The directory for `folder` under `root`, or `nil` for an unusable path.
    static func folderURL(_ folder: String, root: URL = SessionArchive.directory) -> URL? {
        guard let safe = sanitiseFolderPath(folder) else { return nil }
        return root.appendingPathComponent(safe, isDirectory: true)
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
    /// note as a stub, losing the transcript), the transform declines (nil), or
    /// the write fails. `transform` sees the note's real contents, never "".
    private static func rewrite(_ file: SessionFile, _ transform: (String) -> String?) -> Bool {
        guard let existing = readContents(of: file), let updated = transform(existing) else { return false }
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
    /// `context`). A quoted value is decoded (`FrontmatterYAML.scalar`). A
    /// list (a flow list, or a block list as Obsidian writes it) is returned as
    /// a flow list, for `frontmatterTags`. Empty when there's
    /// no frontmatter block.
    static func frontmatter(_ markdown: String) -> [String: String] {
        guard markdown.hasPrefix("---\n") else { return [:] }
        let afterOpen = markdown.index(markdown.startIndex, offsetBy: 4)
        guard let close = markdown.range(of: "\n---\n", range: afterOpen..<markdown.endIndex)
        else { return [:] }
        var out: [String: String] = [:]
        let lines = markdown[afterOpen..<close.lowerBound].split(separator: "\n").map(String.init)
        for group in FrontmatterYAML.entries(lines) {
            let line = group[0]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            // A key with no value and `- item` lines under it is a block list,
            // as Obsidian writes `tags`. It reads as a flow list.
            if value.isEmpty, let items = FrontmatterYAML.blockList(Array(group.dropFirst())) {
                out[key] = FrontmatterYAML.flowList(items)
            } else {
                out[key] = FrontmatterYAML.scalar(value)
            }
        }
        return out
    }

    /// The note body with any leading YAML frontmatter (`---` … `---`) removed,
    /// for display. Without this, markdown reads the `started:`/`ended:` lines
    /// closed by `---` as a setext heading and renders them huge. The session
    /// date is shown separately, so dropping the block loses nothing.
    static func strippingFrontmatter(_ markdown: String) -> String {
        // One split for display and edits alike, so block offsets always agree.
        TranscriptDoc.splitFrontmatter(markdown).body
    }

    /// `markdown` with a single scalar frontmatter `key:` set to `value` (collapsed
    /// to one line, written as a YAML double-quoted string). An empty/blank
    /// `value` removes the key. Pure, for testability. Backs `settingName`.
    static func settingScalar(_ key: String, _ value: String, in markdown: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return settingLine(key, trimmed.isEmpty ? "" : FrontmatterYAML.quoted(trimmed), in: markdown)
    }

    /// `markdown` with the frontmatter `key:` line set to `key: yaml`, where
    /// `yaml` is already valid YAML. An empty `yaml` removes the key. Existing
    /// frontmatter keys and the body are preserved; a note without frontmatter
    /// gains one. The shared core behind `settingScalar`/`settingTags`.
    private static func settingLine(_ key: String, _ yaml: String, in markdown: String) -> String {
        guard markdown.hasPrefix("---\n"),
            let close = markdown.range(
                of: "\n---\n",
                range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex)
        else {
            // No frontmatter: prepend one carrying just this key (nothing to do
            // when clearing a key that was never set).
            return yaml.isEmpty ? markdown : "---\n\(key): \(yaml)\n---\n\n" + markdown
        }
        let open = markdown.index(markdown.startIndex, offsetBy: 4)
        // Drop the key's line and the lines under it (a block list).
        var lines = FrontmatterYAML.entries(
            markdown[open..<close.lowerBound]
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init))
            .filter { !$0[0].hasPrefix("\(key):") }
            .flatMap { $0 }
        if !yaml.isEmpty { lines.append("\(key): \(yaml)") }
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

    /// Parse a comma-separated tags value (a folder's `.tags` file, or the
    /// `tags:` frontmatter of an older note) into names: trimmed, empties
    /// dropped, order preserved. The inverse of `tagsLine`.
    static func parseTags(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The tags in a note's `tags:` frontmatter value: a YAML flow list
    /// (`["a", "b"]`, as `tagsFrontmatter` writes it) or the comma-separated
    /// form of older notes. Trimmed, empties dropped, order preserved.
    static func frontmatterTags(_ value: String) -> [String] {
        guard let items = FrontmatterYAML.list(value) else { return parseTags(value) }
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The tags in the frontmatter of the note `markdown`.
    static func noteTags(_ markdown: String) -> [String] {
        frontmatterTags(frontmatter(markdown)["tags"] ?? "")
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

    /// The canonical list of `tags`: each name normalised, empties dropped, and
    /// case-insensitive duplicates removed (first occurrence wins, order kept).
    static func canonicalTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags {
            let name = normalisedTagName(tag)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// The canonical comma-separated line for `tags` (`canonicalTags`), as a
    /// folder's `.tags` file holds it. "" when there are no usable tags.
    static func tagsLine(_ tags: [String]) -> String {
        canonicalTags(tags).joined(separator: ", ")
    }

    /// The canonical `tags:` frontmatter value for `tags`: `canonicalTags` as a
    /// YAML flow list, `["a", "b"]`. "" when there are no usable tags. The single
    /// source of truth for a note's tag line, shared by `settingTags` and
    /// `SessionMarkdown.inline`.
    static func tagsFrontmatter(_ tags: [String]) -> String {
        let names = canonicalTags(tags)
        return names.isEmpty ? "" : FrontmatterYAML.flowList(names)
    }

    /// `markdown` with its `tags:` frontmatter set to `tags`. An empty list removes
    /// the key. Used to tag a *saved* session — the live note is tagged through
    /// `SessionWriter` instead, to avoid the two-writer clobber.
    static func settingTags(_ tags: [String], in markdown: String) -> String {
        settingLine("tags", tagsFrontmatter(tags), in: markdown)
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
        let tags = noteTags(markdown)
        guard tags.contains(where: { $0.caseInsensitiveCompare(oldTrim) == .orderedSame })
        else { return markdown }
        let renamed = tags.map {
            $0.caseInsensitiveCompare(oldTrim) == .orderedSame ? new : $0
        }
        return settingTags(renamed, in: markdown)
    }

    /// Rename a tag from `old` to `new` across every saved note and folder default
    /// in `directory`, skipping `excluding` (the live note, which is rewritten
    /// through its writer instead). Returns the number of notes changed; folder
    /// metadata is deliberately not included in the count. Entries without the tag
    /// are untouched. Synchronous file I/O — fine for a personal archive of this size.
    @discardableResult
    static func renameTag(
        from old: String, to new: String,
        in directory: URL = SessionArchive.directory, excluding: URL? = nil
    ) -> Int {
        var changed = 0
        for file in list(in: directory) {
            if isSameNote(file.url, excluding) { continue }
            let original = contents(of: file)
            let updated = renamingTag(from: old, to: new, in: original)
            if updated != original,
                (try? updated.write(to: file.url, atomically: true, encoding: .utf8)) != nil {
                changed += 1
            }
        }
        let oldName = old.trimmingCharacters(in: .whitespaces)
        for folder in folders(in: directory) {
            let original = folderTags(folder, root: directory)
            let renamed = original.map {
                $0.caseInsensitiveCompare(oldName) == .orderedSame ? new : $0
            }
            if renamed != original {
                setFolderTags(renamed, for: folder, root: directory)
            }
        }
        return changed
    }

    /// Remove `name` from every folder's defaults after that library tag is
    /// deleted (issue #76). Returns the number of folder metadata files changed.
    /// A folder whose final default is removed loses its `.tags` file entirely.
    @discardableResult
    static func removeTagFromFolderDefaults(
        _ name: String, in directory: URL = SessionArchive.directory
    ) -> Int {
        let removedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = 0
        for folder in folders(in: directory) {
            let original = folderTags(folder, root: directory)
            let filtered = original.filter {
                $0.caseInsensitiveCompare(removedName) != .orderedSame
            }
            if filtered != original,
                setFolderTags(filtered, for: folder, root: directory) {
                changed += 1
            }
        }
        return changed
    }

    /// The notes that a change of the session folder from `source` to `dest`
    /// offers to move: each note in `source` except the live one
    /// (`excluding`). None when the two are one folder by two paths, such as
    /// `sessionDir` through a symlink and the folder it points to, so
    /// Preferences switches the path with no move (issue #114).
    static func notesToMove(from source: URL, to dest: URL, excluding: URL? = nil) -> [SessionFile] {
        guard !isSameFolder(source, dest) else { return [] }
        return list(in: source).filter { !isSameNote($0.url, excluding) }
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
        guard !isSameFolder(source, dest) else { return (0, 0) }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var moved = 0, skipped = 0
        for file in list(in: source) {
            if isSameNote(file.url, excluding) { continue }
            // Preserve folder structure (issues #25, #155): a note in
            // `source/Work/A` lands in `dest/Work/A`, an un-foldered note directly
            // in `dest`.
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
        // Carry each folder's metadata files (context from issue #36, default tags
        // from issue #76), at every depth: `list` doesn't surface hidden files, so
        // move them explicitly, or a storage-dir change would strand the defaults.
        // Never clobbers metadata already at the destination.
        for folder in folders(in: source) {
            let pairs = [
                (folderContextURL(folder, root: source), folderContextURL(folder, root: dest)),
                (folderTagsURL(folder, root: source), folderTagsURL(folder, root: dest)),
            ]
            for (sourceURL, destinationURL) in pairs {
                guard let sourceURL, let destinationURL,
                    FileManager.default.fileExists(atPath: sourceURL.path),
                    !FileManager.default.fileExists(atPath: destinationURL.path) else { continue }
                try? FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            }
        }
        return (moved, skipped)
    }

    /// Create folder `name` under `directory` (issue #25), or inside the folder
    /// `parent` (issue #155). A new subfolder starts with a copy of its parent's
    /// context and default tags; it keeps no link to them, so a later edit of
    /// either changes only that folder. Returns false for an unusable name
    /// (`sanitiseFolderName`) or parent (`sanitiseFolderPath`), or a failed
    /// `createDirectory`. Idempotent: creating a folder that already exists
    /// succeeds and leaves its own context and tags as they are.
    @discardableResult
    static func createFolder(
        _ name: String, inside parent: String? = nil, in directory: URL = SessionArchive.directory
    ) -> Bool {
        guard let leaf = sanitiseFolderName(name) else { return false }
        var folder = leaf
        if let parent {
            guard let safeParent = sanitiseFolderPath(parent) else { return false }
            folder = "\(safeParent)/\(leaf)"
        }
        guard let url = folderURL(folder, root: directory) else { return false }
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: url.path)
        guard (try? fm.createDirectory(at: url, withIntermediateDirectories: true)) != nil
        else { return false }
        if isNew, let parent {
            setFolderContext(folderContext(parent, root: directory), for: folder, root: directory)
            setFolderTags(folderTags(parent, root: directory), for: folder, root: directory)
        }
        return true
    }

    /// The hidden file holding a folder's context (issue #36):
    /// `<root>/<folder>/.context.md`. `nil` for an unusable folder path. Dot-prefixed
    /// and not a session-date name, so `list`/`folders` ignore it (a file, not a
    /// directory), and it travels with the directory on `renameFolder`.
    static func folderContextURL(_ folder: String, root: URL = SessionArchive.directory) -> URL? {
        folderURL(folder, root: root)?.appendingPathComponent(".context.md")
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

    /// The hidden file holding a folder's default tags (issue #76):
    /// `<root>/<folder>/.tags`. It travels with the directory on rename and is
    /// ignored by session listing.
    static func folderTagsURL(_ folder: String, root: URL = SessionArchive.directory) -> URL? {
        folderURL(folder, root: root)?.appendingPathComponent(".tags")
    }

    /// A folder's default session tags (issue #76), or an empty list when unset.
    /// Uses the same canonical comma-separated representation as note frontmatter.
    static func folderTags(_ folder: String, root: URL = SessionArchive.directory) -> [String] {
        guard let url = folderTagsURL(folder, root: root),
            let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseTags(text)
    }

    /// Set (or clear) the tags inherited by new recordings started in `folder`
    /// (issue #76). Empty tags remove the metadata file. Creates an empty folder
    /// when needed, mirroring `setFolderContext`.
    @discardableResult
    static func setFolderTags(
        _ tags: [String], for folder: String, root: URL = SessionArchive.directory
    ) -> Bool {
        guard let url = folderTagsURL(folder, root: root) else { return false }
        let fm = FileManager.default
        let line = tagsLine(tags)
        if line.isEmpty {
            guard fm.fileExists(atPath: url.path) else { return true }
            return (try? fm.removeItem(at: url)) != nil
        }
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: url, atomically: true, encoding: .utf8)
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
            guard let safe = sanitiseFolderPath(folder) else { return nil }
            folderName = safe
        } else {
            folderName = nil
        }
        // Un-filing the last note leaves its source folder behind empty by design:
        // empty folders persist (see `folders`), so the folder doesn't vanish from
        // the sidebar just because its final session moved out.
        // Built from the resolved root, so the new URL equals the one that `list`
        // gives after the move, and the browser keeps its selection (issue #114).
        let base = resolvedFolder(root)
        let targetDir = folderName.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
        let dest = targetDir.appendingPathComponent(file.url.lastPathComponent)
        if isSameNote(dest, file.url) {
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

    /// `url` as the file system names it: standardised, with its folder
    /// resolved (`resolvedFolder`; issue #114). `contentsOfDirectory` returns
    /// resolved paths, so a row from `list` and a URL built from an unresolved
    /// `sessionDir` can name one note by two paths. Only the folder is
    /// resolved: the writer's note is a plain file, so its name needs no
    /// resolution, and a note that does not exist yet keeps its name.
    static func resolvedNoteURL(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        return resolvedFolder(standard.deletingLastPathComponent())
            .appendingPathComponent(standard.lastPathComponent)
    }

    /// True when `a` and `b` name the same note on disk (issue #114). Every
    /// check for the live note uses it, so a browser row and the writer's URL
    /// match through a symlinked `sessionDir`. Two file names are two notes,
    /// and then the check makes no file system call, so it stays cheap in a
    /// view that redraws as an answer streams.
    static func isSameNote(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        let (x, y) = (a.standardizedFileURL, b.standardizedFileURL)
        guard x.lastPathComponent == y.lastPathComponent else { return false }
        return resolvedNoteURL(x).path == resolvedNoteURL(y).path
    }

    /// A folder mutation must not move a note still owned by the live writer.
    /// True for a note in `folder` or in any of its subfolders (issue #155).
    /// Resolve aliases and include the separator so `Workshops` is not `Work`.
    static func folderContains(
        _ note: URL?, folder: String, in directory: URL = SessionArchive.directory
    ) -> Bool {
        guard let note, let url = folderURL(folder, root: directory) else { return false }
        let parent = resolvedFolder(url).path.lowercased()
        let path = resolvedNoteURL(note).path.lowercased()
        return path.hasPrefix(parent + "/")
    }

    /// Rename the folder at path `old` to the name `new` under `directory`
    /// (issue #25) by moving the directory — its notes and subfolders travel with
    /// it. The folder stays in its parent (issue #155): `new` is one name, not a
    /// path. Returns false for an unusable `new` name, a missing source, or a
    /// collision with a *different* existing folder. A case-only rename (`work` →
    /// `Work`) on a case-insensitive volume is allowed.
    @discardableResult
    static func renameFolder(
        from old: String, to new: String, in directory: URL = SessionArchive.directory,
        excluding ownedNote: URL? = nil
    ) -> Bool {
        guard let newName = sanitiseFolderName(new),
            let oldPath = sanitiseFolderPath(old) else { return false }
        guard !folderContains(ownedNote, folder: oldPath, in: directory) else { return false }
        let fm = FileManager.default
        let src = directory.appendingPathComponent(oldPath, isDirectory: true)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return false }
        if src.standardizedFileURL == dst.standardizedFileURL { return true }
        // Block only a collision with a genuinely different folder; a case-only
        // rename resolves to the same path case-insensitively and must go through.
        let sameNameCaseInsensitive = src.standardizedFileURL.path
            .compare(dst.standardizedFileURL.path, options: .caseInsensitive) == .orderedSame
        if !sameNameCaseInsensitive, fm.fileExists(atPath: dst.path) { return false }
        return (try? fm.moveItem(at: src, to: dst)) != nil
    }

    /// Hidden files that macOS writes into a folder: Finder's view settings and
    /// localisation marker, a custom folder icon, and the AppleDouble `._` files
    /// on a volume that cannot hold extended attributes. They do not keep a
    /// deleted folder, and are deleted with it.
    static func isSystemFile(_ name: String) -> Bool {
        [".DS_Store", ".localized", "Icon\r"].contains(name) || name.hasPrefix("._")
    }

    /// Delete the folder at path `name` (issue #25) without deleting its
    /// sessions: each note directly in it, and each subfolder with all that it
    /// holds, moves into the folder's parent — `directory` for a top-level
    /// folder (issue #155). Nothing moves when a name is already used in the
    /// parent (or is the folder itself, as for `Work/Work`), or when the folder
    /// holds a file that is not a session, such as a package, so a refused
    /// delete leaves the folder as it was. When a move fails, the moves before
    /// it are put back. Then the folder holds only its context, its tags and
    /// the files that macOS writes (`isSystemFile`), which are deleted with it;
    /// if that fails (a locked file), the moves are put back too.
    /// The contents are checked once: nothing else is assumed to change the
    /// folder during the delete. Returns true when the folder was removed.
    @discardableResult
    static func deleteFolder(
        _ name: String, in directory: URL = SessionArchive.directory,
        excluding ownedNote: URL? = nil
    ) -> Bool {
        guard let safe = sanitiseFolderPath(name) else { return false }
        guard !folderContains(ownedNote, folder: safe, in: directory) else { return false }
        let fm = FileManager.default
        let folderURL = directory.appendingPathComponent(safe, isDirectory: true)
        let parentURL = folderURL.deletingLastPathComponent()
        let metadataNames = [folderContextURL(safe, root: directory), folderTagsURL(safe, root: directory)]
            .compactMap { $0?.lastPathComponent }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: Array(keys)) else { return false }
        var notes: [(from: URL, to: URL)] = []
        var subfolders: [(from: URL, to: URL)] = []
        for entry in entries {
            let entryName = entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? false
            if isDir && !(values?.isPackage ?? false) && !entryName.hasPrefix(".") {
                subfolders.append((entry, parentURL.appendingPathComponent(entryName, isDirectory: true)))
            } else if !isDir && date(from: entryName) != nil {
                notes.append((entry, parentURL.appendingPathComponent(entryName)))
            } else if isDir || !(isSystemFile(entryName) || metadataNames.contains(entryName)) {
                return false
            }
        }
        // Notes first, so a test can make a subfolder's move fail after them.
        let moves = notes + subfolders
        guard !moves.contains(where: { fm.fileExists(atPath: $0.to.path) }) else { return false }
        var done: [(from: URL, to: URL)] = []
        func undo() -> Bool {
            for back in done.reversed() { try? fm.moveItem(at: back.to, to: back.from) }
            return false
        }
        for move in moves {
            guard (try? fm.moveItem(at: move.from, to: move.to)) != nil else { return undo() }
            done.append(move)
        }
        // A file locked in Finder stops the removal: put the moves back.
        return (try? fm.removeItem(at: folderURL)) != nil || undo()
    }

    /// Run a save against `file`, and once more against where it is now if it
    /// has moved (filed into a folder meanwhile) — a long Ask, Summarise,
    /// research or follow-up can outlast the note's path, and a note can be moved
    /// from outside the app while its pane is open (issue #94). A deleted note
    /// has nowhere to go, so the save fails rather than recreating it. The
    /// `attempt` is the whole setter, so one that checks the block it expects
    /// (`expecting:`) checks it at the new path too, and a lookalike of the same
    /// name there is refused as it would be at the old; a setter without such a
    /// check (a summary, follow-up, card or "all in session") writes into it.
    static func save(
        to file: SessionFile, in directory: URL = SessionArchive.directory, _ attempt: (SessionFile) -> Bool
    ) -> Bool {
        if attempt(file) { return true }
        guard let moved = relocated(file, in: directory), moved.url != file.url else { return false }
        return attempt(moved)
    }

    /// `file` where it is now: itself if it's still there, else the note with the
    /// same file name elsewhere in the archive (moved into or out of a folder
    /// meanwhile), or nil if it's gone.
    static func relocated(_ file: SessionFile, in directory: URL = SessionArchive.directory) -> SessionFile? {
        if FileManager.default.fileExists(atPath: file.url.path) { return file }
        return list(in: directory).first { $0.url.lastPathComponent == file.url.lastPathComponent }
    }

    /// `file` where it is now (`relocated`) and its markdown, or nil when the
    /// note has gone or can't be read (issue #115). Summarise, Ask, a follow-up
    /// and a research card read the note through this
    /// (`SessionDetailPane.startRequest`), so a note moved outside the app is
    /// read at its new path, and an unreadable note sends nothing. Before, they
    /// read "" at the old path, and the answer to that empty transcript was
    /// saved into the moved note.
    static func readRelocated(
        _ file: SessionFile, in directory: URL = SessionArchive.directory
    ) -> (file: SessionFile, markdown: String)? {
        guard let note = relocated(file, in: directory), let markdown = readContents(of: note) else { return nil }
        return (note, markdown)
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

    /// Remove the card or editorial note at block `offset` from `file` on disk
    /// (`NoteEdit.removingBlock`). Returns false — leaving the note untouched —
    /// when the block there is no longer `block`, the note can't be read, or the
    /// write fails.
    @discardableResult
    static func removeBlock(at offset: Int, expecting block: TranscriptBlock, from file: SessionFile) -> Bool {
        rewrite(file) { NoteEdit.removingBlock(at: offset, expecting: block, in: $0) }
    }

    /// Insert an editorial note into `file` on disk after the transcript line
    /// that character `offset` of the paragraph at block `paragraphOffset` falls
    /// in (`NoteEdit.insertingNote`). Returns false — leaving the note untouched —
    /// when that paragraph is no longer `block`, the note can't be read, or the
    /// write fails.
    @discardableResult
    static func insertNote(
        _ text: String, inParagraphAt paragraphOffset: Int, expecting block: TranscriptBlock,
        atCharacter offset: Int, in file: SessionFile
    ) -> Bool {
        rewrite(file) {
            NoteEdit.insertingNote(
                text, inParagraphAt: paragraphOffset, expecting: block, atCharacter: offset, in: $0)
        }
    }

    /// Add an editorial note to `file` on disk at the end of its transcript
    /// (`NoteEdit.appendingNote`). Returns false — leaving the note untouched — for
    /// blank text, or when the note can't be read or the write fails.
    @discardableResult
    static func appendNote(_ text: String, in file: SessionFile) -> Bool {
        rewrite(file) { NoteEdit.appendingNote(text, in: $0) }
    }

    /// Insert a finished card `block` into `file` on disk under `anchor`'s
    /// transcript line, or at the end of the transcript if it has gone
    /// (`NoteEdit.insertingBlock`). Returns false when the note can't be read or
    /// the write fails.
    @discardableResult
    static func insertBlock(_ block: String, after anchor: NoteEdit.Anchor, in file: SessionFile) -> Bool {
        rewrite(file) { NoteEdit.insertingBlock(block, after: anchor, in: $0) }
    }

    /// Replace the body of the card with id `id` in `file` on disk — a follow-up
    /// appended (`NoteEdit.replacingCardBody`). Returns false — leaving the note
    /// untouched — when the card has gone or changed, the note can't be read, or
    /// the write fails.
    @discardableResult
    static func replaceCardBody(ofCard id: String, body old: String, with new: String, in file: SessionFile) -> Bool {
        rewrite(file) { NoteEdit.replacingCardBody(ofCard: id, body: old, with: new, in: $0) }
    }

    /// Correct a transcription error in a saved note (issue #32): replace the
    /// `occurrence`-th match of `original` within the transcript paragraph at block
    /// `paragraphOffset` with `replacement` (`NoteEdit.correctingOccurrence`).
    /// Frontmatter and cards are left untouched. Returns false — leaving the note
    /// untouched — when that paragraph is no longer `block` (issue #91), nothing
    /// changed, the note can't be read, or the write fails. Saved-note only — the
    /// live note is corrected through its `TranscriptStore` instead, to avoid the
    /// writer clobber.
    @discardableResult
    static func correctOccurrence(
        _ occurrence: Int, of original: String, with replacement: String,
        inParagraphAt paragraphOffset: Int, expecting block: TranscriptBlock, of file: SessionFile
    ) -> Bool {
        rewrite(file) {
            NoteEdit.correctingOccurrence(
                occurrence, of: original, with: replacement, inParagraphAt: paragraphOffset,
                expecting: block, in: $0)
        }
    }

    /// Correct every occurrence of `original` in a saved note's transcript with
    /// `replacement` (issue #32). Only the transcript utterance lines change —
    /// frontmatter, cards, and follow-ups are left byte-identical. Returns false if
    /// nothing changed, the note can't be read, or the write fails.
    @discardableResult
    static func correctAll(
        of original: String, with replacement: String, in file: SessionFile
    ) -> Bool {
        rewrite(file) { existing in
            let updated = TranscriptCorrection.replacingAllInTranscript(
                of: original, with: replacement, inMarkdown: existing)
            return updated == existing ? nil : updated
        }
    }
}
