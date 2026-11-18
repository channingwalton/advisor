import Foundation

/// Flat paths for the sidebar's plain rows, ordered as a tree rather than a
/// global path sort (which can put a sibling between a parent and its child).
enum SessionFolderTree {
    static func ancestors(of folder: String) -> [String] {
        let parts = folder.components(separatedBy: "/")
        return (1..<parts.count).map { parts.prefix($0).joined(separator: "/") }
    }

    static func visible(
        folders: [String], matching: Set<String>?, collapsed: Set<String>
    ) -> [String] {
        let included = matching.map { matches in
            matches.reduce(into: matches) { $0.formUnion(ancestors(of: $1)) }
        }
        let byParent = Dictionary(grouping: folders) { folder in
            ancestors(of: folder).last ?? ""
        }
        var result: [String] = []
        func visit(_ parent: String) {
            for folder in (byParent[parent] ?? []).sorted(by: {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }) {
                guard included?.contains(folder) != false else { continue }
                result.append(folder)
                // Search reveals matches even below a collapsed ancestor.
                if matching != nil || !collapsed.contains(folder) { visit(folder) }
            }
        }
        visit("")
        return result
    }
}
