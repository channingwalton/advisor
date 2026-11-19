import Foundation

/// The Sessions sidebar's folder tree (issue #155), as pure functions over
/// folder paths such as `Work/Client A`. The paths come in tree order
/// (`SessionArchive.folders`), so each folder comes just before its subfolders.
enum FolderTree {
    /// The folders to show, in tree order. A folder is hidden when one of its
    /// ancestors is in `collapsed`. While a search runs, `matching` holds the
    /// folders that hold a matching session, and a folder shows only when it or
    /// one of its subfolders is one of them; `nil` shows every folder, so empty
    /// folders still appear and can be managed.
    static func visible(_ folders: [String], collapsed: Set<String>, matching: Set<String>?) -> [String] {
        folders.filter { folder in
            if collapsed.contains(where: { SessionArchive.isFolder(folder, inside: $0) }) { return false }
            guard let matching else { return true }
            return matching.contains { $0 == folder || SessionArchive.isFolder($0, inside: folder) }
        }
    }

    /// How many of the sessions, given by their folders, are in `folder` or in
    /// one of its subfolders.
    static func sessionCount(of folder: String, in sessionFolders: [String?]) -> Int {
        sessionFolders.filter { $0 == folder || $0.map { SessionArchive.isFolder($0, inside: folder) } == true }
            .count
    }

    /// The folders directly inside `parent`, or the top-level folders for `nil`,
    /// in tree order.
    static func children(of parent: String?, in folders: [String]) -> [String] {
        folders.filter { SessionArchive.parentFolder($0) == parent }
    }

    /// One part of the sidebar's folder area: a folder's header, or the place
    /// for the sessions directly in a folder.
    enum Entry: Hashable {
        case header(String)
        case sessions(String)
    }

    /// The order of the folder area for `folders` in tree order: each folder's
    /// header, then its subfolders, then its own sessions, as in Finder's list
    /// view with folders first.
    static func layout(_ folders: [String]) -> [Entry] {
        var entries: [Entry] = []
        var open: [String] = []
        for folder in folders {
            while let last = open.last, !SessionArchive.isFolder(folder, inside: last) {
                entries.append(.sessions(open.removeLast()))
            }
            entries.append(.header(folder))
            open.append(folder)
        }
        while let last = open.popLast() { entries.append(.sessions(last)) }
        return entries
    }

    /// The collapsed folders after `old` is renamed to the path `new`: the
    /// folder and each of its subfolders keep their state under the new path.
    static func renaming(_ collapsed: Set<String>, from old: String, to new: String) -> Set<String> {
        Set(collapsed.map { folder in
            if folder == old { return new }
            if SessionArchive.isFolder(folder, inside: old) { return new + folder.dropFirst(old.count) }
            return folder
        })
    }

    /// The collapsed folders after `folder` is deleted: its subfolders move to
    /// other paths, so their entries go too.
    static func removing(_ collapsed: Set<String>, folder: String) -> Set<String> {
        collapsed.filter { $0 != folder && !SessionArchive.isFolder($0, inside: folder) }
    }

    /// The collapsed folders with `folder` and each folder that holds it
    /// expanded, so that `folder` shows.
    static func expanding(_ collapsed: Set<String>, toShow folder: String) -> Set<String> {
        collapsed.filter { $0 != folder && !SessionArchive.isFolder(folder, inside: $0) }
    }

    /// A folder path as the user reads it: `Work › Client A`.
    static func displayPath(_ folder: String) -> String {
        folder.split(separator: "/").joined(separator: " › ")
    }
}
