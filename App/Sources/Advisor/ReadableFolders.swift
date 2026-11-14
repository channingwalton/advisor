import Foundation

/// The folders that the Claude agents may read: `readableFolders` in
/// config.json (GHSA-6xc8-f55f-jxqr). The sidecar reads the list from the file
/// at each file-tool call and enforces it (`readableRoots` in
/// sidecar/src/toolPolicy.ts). This is the app's side: the edits that Preferences →
/// Files makes. Each edit reads the file's list at that moment, so a copy of
/// the config that a window loaded earlier never writes the list.
///
/// The list is read and written in the raw JSON object, by the sidecar's rule
/// (`mergeConfig`: the string entries of a list, else none), not through the
/// `AdvisorConfig` decode. So the tab shows and edits the list that the
/// sidecar uses even when another key has a value that the app cannot decode,
/// and an edit leaves every other key as the file holds it (code review
/// 2026-11-10).
enum ReadableFolders {
    /// The list in the file at `url`: none when there is no file, nil when the
    /// file cannot be read or is not a JSON object.
    static func load(from url: URL = AdvisorConfig.fileURL) -> [String]? {
        switch ConfigFile.read(at: url) {
        case .missing: return []
        case .unusable: return nil
        case .object(let json, _): return list(in: json)
        }
    }

    /// What an edit did.
    enum Outcome: Equatable {
        /// The file holds the new list.
        case saved([String])
        /// The file cannot be read, is not a JSON object, or is JSON that the
        /// sidecar reads in another way, so nothing was written.
        case unusable
        /// The write failed; the file still holds this list.
        case notSaved([String])
    }

    /// Apply `change` to the list in the file at `url` as it is now, and save.
    /// With no file, the change applies to an empty list and the file is made.
    /// A file that cannot be read or is not a JSON object is left as it is: its
    /// list is unknown. A failed write reports the list that the file still
    /// holds, so a removed folder never looks removed while agents can still
    /// read it.
    static func update(
        at url: URL = AdvisorConfig.fileURL, _ change: ([String]) -> [String]
    ) -> Outcome {
        var json: [String: Any]
        switch ConfigFile.read(at: url) {
        case .missing: json = [:]
        case .unusable:
            appLog.write("readable folders not changed: config.json cannot be read or is not a JSON object")
            return .unusable
        case .object(let disk, _): json = disk
        }
        let before = list(in: json)
        let after = change(before)
        json["readableFolders"] = after
        return ConfigFile.write(json, to: url) ? .saved(after) : .notSaved(before)
    }

    /// The sidecar's rule: the string entries of a list, else none.
    private static func list(in json: [String: Any]) -> [String] {
        (json["readableFolders"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The Files tab's Add: each of `folders` that the file's list lacks.
    static func add(
        _ folders: [String], at url: URL = AdvisorConfig.fileURL, home: String = NSHomeDirectory()
    ) -> Outcome {
        update(at: url) { list in folders.reduce(list) { adding($1, to: $0, home: home) } }
    }

    /// The Files tab's Remove: `folder` out of the file's list, in every
    /// spelling. It edits the file's list, not the list that the tab shows.
    static func remove(
        _ folder: String, at url: URL = AdvisorConfig.fileURL, home: String = NSHomeDirectory()
    ) -> Outcome {
        update(at: url) { removing(folder, from: $0, home: home) }
    }

    /// `list` with `folder` at the end, unless the list holds it already in
    /// another spelling of the same resolved path: absolute or `~/…`, with a
    /// trailing `/` or a `..`, or through a symlink or in another letter case.
    /// A folder that does not exist yet keeps the letter case that it was
    /// given, so two such spellings are both added.
    static func adding(_ folder: String, to list: [String], home: String = NSHomeDirectory()) -> [String] {
        let key = normalised(folder, home: home)
        return list.contains { normalised($0, home: home) == key } ? list : list + [folder]
    }

    /// `list` without `folder` in any spelling, so one Remove revokes the
    /// folder however often the list holds it. An entry goes when one of the
    /// folders that the sidecar grants for it is one of `folder`'s
    /// (`forms`). Letter case is folded here, as APFS folds it (`Noteſ`
    /// opens `Notes`): a folder that does not exist yet keeps the spelling it
    /// was given, and the sidecar may later resolve two spellings to one
    /// folder (code review 2026-11-10). To remove too much fails closed.
    static func removing(_ folder: String, from list: [String], home: String = NSHomeDirectory()) -> [String] {
        let fold = { (form: String) in form.folding(options: [.caseInsensitive], locale: nil) }
        let keys = Set(forms(folder, home: home).map(fold))
        return list.filter { keys.isDisjoint(with: forms($0, home: home).map(fold)) }
    }

    /// An entry as Preferences shows it: the home folder as `~`.
    static func display(_ folder: String, home: String = NSHomeDirectory()) -> String {
        if folder == home { return "~" }
        if folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    /// The folders that the sidecar grants for an entry (`readableRoots` in
    /// sidecar/src/toolPolicy.ts): `~` expanded, then the lexical form, the
    /// resolved form and the resolved lexical form. A `..` after a symlink
    /// makes the last two differ: the kernel follows the symlink before it
    /// applies the `..`. The sidecar ignores a relative entry, so such an
    /// entry matches only itself.
    private static func forms(_ folder: String, home: String) -> Set<String> {
        guard let abs = absolute(folder, home: home) else { return ["relative:" + folder] }
        let lex = lexical(abs)
        return [lex, resolved(abs), resolved(lex)]
    }

    /// An entry as the folder that Add compares: its lexical form resolved
    /// to the names that the disk stores, through symlinks and in the disk's
    /// letter case (code review 2026-11-10).
    private static func normalised(_ folder: String, home: String) -> String {
        guard let abs = absolute(folder, home: home) else { return "relative:" + folder }
        return resolved(lexical(abs))
    }

    /// `folder` with `~` expanded, or nil when it is not absolute then.
    private static func absolute(_ folder: String, home: String) -> String? {
        let expanded =
            folder == "~" ? home : folder.hasPrefix("~/") ? home + folder.dropFirst(1) : folder
        return expanded.hasPrefix("/") ? expanded : nil
    }

    /// `path` with `.` and `..` applied by name, as Node's `path.resolve`
    /// applies them: no symlink is followed.
    private static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// realpath(3) of `path`, as the sidecar's `canonical`: the names that
    /// the disk stores, with each symlink followed where the kernel follows
    /// it. For a path that does not exist, its deepest existing parent is
    /// resolved and the rest appended, as the sidecar's `realResolve` does.
    private static func resolved(_ path: String) -> String {
        var current = path
        var tail: [Substring] = []
        while true {
            if let real = realpath(current, nil) {
                defer { free(real) }
                return lexical(([Substring(String(cString: real))] + tail.reversed()).joined(separator: "/"))
            }
            guard let slash = current.lastIndex(of: "/"), current != "/" else { return lexical(path) }
            tail.append(current[current.index(after: slash)...])
            current = slash == current.startIndex ? "/" : String(current[..<slash])
        }
    }
}
