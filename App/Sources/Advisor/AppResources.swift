import Foundation

/// Locates runtime resources (sidecar, Node, whisper model) for both layouts:
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

    /// Whisper model path. Order: explicit env override, then the user's
    /// Application Support models dir (where a downloaded model lands), then the
    /// dev vendor tree. The model is optional — Apple SpeechAnalyzer is the
    /// default engine and needs none.
    static var defaultModelPath: String {
        if let env = ProcessInfo.processInfo.environment["ADVISOR_WHISPER_MODEL"] {
            return env
        }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Advisor/models/ggml-large-v3-turbo.bin")
        if let appSupport, FileManager.default.fileExists(atPath: appSupport.path) {
            return appSupport.path
        }
        return repoRoot
            .appendingPathComponent("vendor/whisper.cpp/models/ggml-large-v3-turbo.bin").path
    }
}
