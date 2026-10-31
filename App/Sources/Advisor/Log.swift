import Foundation

/// Shared app logger. Use `appLog.write(_:)` instead of writing to stderr
/// directly so messages land in the standard macOS user logs folder.
let appLog = FileLog()

/// File logging to the standard macOS user logs folder
/// (`~/Library/Logs/Advisor/advisor.log`), mirrored to stderr for dev runs.
///
/// The app is the *sole* writer of the file: its own messages arrive via
/// `write`, and the Node sidecar's stderr is funnelled in via `appendSidecar`
/// from `SidecarManager`. A single serial queue serialises every write, so the
/// file has no contention and keeps one chronological timeline. Rotates by
/// size, keeping one previous file (`advisor.log.1`).
final class FileLog {
    /// The logs folder, for other diagnostics to save beside the log.
    let directory: URL
    private let fileURL: URL
    private let rotatedURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "advisor.log")
    private let formatter: ISO8601DateFormatter
    private var handle: FileHandle?
    private var size = 0
    /// Holds an incomplete trailing line from the sidecar stream between chunks.
    private var sidecarBuffer = Data()

    /// - Parameters:
    ///   - directory: target folder; defaults to `~/Library/Logs/Advisor`.
    ///   - maxBytes: rotate once the live file would exceed this size.
    init(directory: URL? = nil, maxBytes: Int = 5_000_000) {
        let dir = directory ?? FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Advisor")
        self.directory = dir
        fileURL = dir.appendingPathComponent("advisor.log")
        rotatedURL = dir.appendingPathComponent("advisor.log.1")
        self.maxBytes = maxBytes
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter = f
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Append one app log line. A timestamp is prepended and a newline added.
    func write(_ message: String) {
        queue.async { self.emit(message) }
    }

    /// Funnel a chunk of the sidecar's stderr. Chunks can split mid-line, so
    /// complete lines are assembled here and each is timestamped on its own.
    func appendSidecar(_ data: Data) {
        queue.async {
            self.sidecarBuffer.append(data)
            while let nl = self.sidecarBuffer.firstIndex(of: 0x0A) {
                let lineData = self.sidecarBuffer[self.sidecarBuffer.startIndex..<nl]
                self.sidecarBuffer.removeSubrange(self.sidecarBuffer.startIndex...nl)
                let line = String(decoding: lineData, as: UTF8.self)
                if !line.isEmpty { self.emit(line) }
            }
        }
    }

    /// Emit any buffered partial sidecar line. Call on sidecar exit so the last
    /// (unterminated) line isn't lost.
    func flushSidecar() {
        queue.async {
            let line = String(decoding: self.sidecarBuffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.sidecarBuffer.removeAll()
            if !line.isEmpty { self.emit(line) }
        }
    }

    /// Block until queued writes have drained (tests, and ⌘Q before `_exit`).
    func flush() { queue.sync {} }

    // MARK: - serial-queue internals (only ever run on `queue`)

    private func emit(_ message: String) {
        let bytes = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        FileHandle.standardError.write(bytes)   // dev mirror
        do {
            var h = try openHandle()
            if size > 0, size + bytes.count > maxBytes {
                rotate()
                h = try openHandle()
            }
            try h.write(contentsOf: bytes)
            size += bytes.count
        } catch {
            FileHandle.standardError.write(
                Data("[advisor] log write failed: \(error)\n".utf8))
        }
    }

    private func openHandle() throws -> FileHandle {
        if let handle { return handle }
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            size = ((try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
        } else {
            fm.createFile(atPath: fileURL.path, contents: nil)
            size = 0
        }
        let h = try FileHandle(forWritingTo: fileURL)
        h.seekToEndOfFile()
        handle = h
        return h
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        size = 0
    }
}
