import Testing
import Foundation

@testable import Advisor

/// A throwaway logs directory, removed on teardown.
private func makeLogDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("advisor-log-test-\(UUID().uuidString)")
    return dir
}

@Test func writeAppendsTimestampedLineToFile() throws {
    let dir = makeLogDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = FileLog(directory: dir)

    log.write("[advisor] hello world")
    log.flush()

    let contents = try String(contentsOf: dir.appendingPathComponent("advisor.log"), encoding: .utf8)
    #expect(contents.contains("[advisor] hello world"))
    #expect(contents.hasSuffix("\n"))
    // Leading ISO-8601 timestamp (year prefix is enough to prove it's stamped).
    #expect(contents.hasPrefix("20"))
}

@Test func writePreservesOrderAcrossLines() throws {
    let dir = makeLogDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = FileLog(directory: dir)

    log.write("first")
    log.write("second")
    log.write("third")
    log.flush()

    let contents = try String(contentsOf: dir.appendingPathComponent("advisor.log"), encoding: .utf8)
    let lines = contents.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0].hasSuffix("first"))
    #expect(lines[1].hasSuffix("second"))
    #expect(lines[2].hasSuffix("third"))
}

@Test func rotationMovesFullFileToBackup() throws {
    let dir = makeLogDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Tiny cap so a couple of lines force a rotation.
    let log = FileLog(directory: dir, maxBytes: 60)

    log.write("line-one-padding-padding-padding")   // fills past the cap
    log.write("line-two-after-rotation")
    log.flush()

    let fm = FileManager.default
    let live = dir.appendingPathComponent("advisor.log")
    let backup = dir.appendingPathComponent("advisor.log.1")
    #expect(fm.fileExists(atPath: backup.path))
    let liveContents = try String(contentsOf: live, encoding: .utf8)
    let backupContents = try String(contentsOf: backup, encoding: .utf8)
    #expect(liveContents.contains("line-two-after-rotation"))
    #expect(!liveContents.contains("line-one-padding"))
    #expect(backupContents.contains("line-one-padding"))
}

@Test func sidecarStreamAssemblesLinesAcrossChunks() throws {
    let dir = makeLogDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = FileLog(directory: dir)

    log.appendSidecar(Data("[sidecar +1.0s] ready\n[sid".utf8))
    log.appendSidecar(Data("ecar +2.0s] done\n".utf8))
    log.flush()

    let contents = try String(contentsOf: dir.appendingPathComponent("advisor.log"), encoding: .utf8)
    let lines = contents.split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines[0].hasSuffix("[sidecar +1.0s] ready"))
    #expect(lines[1].hasSuffix("[sidecar +2.0s] done"))
}

@Test func sidecarPartialLineIsBufferedUntilNewline() throws {
    let dir = makeLogDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = FileLog(directory: dir)

    // No trailing newline: nothing should be written yet.
    log.appendSidecar(Data("[sidecar +1.0s] partial".utf8))
    log.flush()
    let path = dir.appendingPathComponent("advisor.log").path
    let beforeFlush = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    #expect(!beforeFlush.contains("partial"))

    // flushSidecar emits the buffered remainder (e.g. on process exit).
    log.flushSidecar()
    log.flush()
    let afterFlush = try String(contentsOfFile: path, encoding: .utf8)
    #expect(afterFlush.contains("[sidecar +1.0s] partial"))
}
