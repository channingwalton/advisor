import Foundation

// Repo root, derived from this source file's compile-time location so the
// checkout can move without editing paths. Sources/Advisor/AppResources.swift
// is four levels below the repo root (…/App/Sources/Advisor/AppResources.swift).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Advisor/
    .deletingLastPathComponent()   // Sources/
    .deletingLastPathComponent()   // App/
    .deletingLastPathComponent()   // repo root

/// Locates runtime resources (sidecar, Node) for both layouts:
/// a packaged `.app` (resources under `Contents/Resources`) and a dev checkout
/// (resources under the repo tree, derived from `repoRoot`). Packaged paths win
/// when present, so the same binary runs either way.
enum AppResources {
    /// `Contents/Resources/sidecar` when running from a packaged app, else nil.
    private static var bundledSidecar: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("sidecar"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Working directory for the Node sidecar (holds `dist/main.js`).
    static var sidecarDir: String {
        bundledSidecar?.path ?? repoRoot.appendingPathComponent("sidecar").path
    }

    /// Absolute path to the bundled Node binary, or nil in a dev checkout
    /// (caller falls back to resolving `node` via the login shell PATH).
    static var bundledNode: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("node"),
            FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url.path
    }

    /// The terms document (TERMS.md): the bundled copy when packaged
    /// (package.sh), the repo root in a dev checkout.
    static var termsURL: URL {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("TERMS.md"),
            FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return repoRoot.appendingPathComponent("TERMS.md")
    }
}
