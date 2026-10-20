import Foundation
import Testing

@testable import Advisor

// The app builds under the Xcode pinned in .xcode-version, here and in CI:
// App/xcode.sh finds that version among the installed Xcodes and runs the
// command with DEVELOPER_DIR pointing at it, or refuses to run it at all.

/// A folder of fake Xcode apps, each only an Info.plist carrying its version.
private func fakeXcodes(_ versions: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("advisor-xcodes-\(UUID().uuidString)")
    for (name, version) in versions {
        let contents = dir.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }
    return dir
}

/// Runs `command` through App/xcode.sh over the Xcodes in `apps`; by default
/// the command prints the DEVELOPER_DIR it was given.
private func runPinned(
    apps: URL, command: [String] = ["/bin/sh", "-c", "printf %s \"$DEVELOPER_DIR\""]
) throws -> (status: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [repoRoot.appendingPathComponent("App/xcode.sh").path] + command
    process.environment = ["XCODE_APPS_DIR": apps.path, "PATH": "/usr/bin:/bin"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    )
}

private func pinnedXcode() throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent(".xcode-version"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func aCommandRunsUnderThePinnedXcode() throws {
    let pin = try pinnedXcode()
    // Xcode.app, another version, sorts first, as the default does on CI's image.
    let apps = try fakeXcodes(["Xcode": "\(pin).1", "Xcode_\(pin)": pin])
    defer { try? FileManager.default.removeItem(at: apps) }
    let run = try runPinned(apps: apps)
    #expect(run.status == 0, "\(run.err)")
    #expect(run.out == apps.appendingPathComponent("Xcode_\(pin).app/Contents/Developer").path)
}

/// A failing swift step must fail the check that runs it, so the command's
/// exit status comes back, and its arguments arrive as given.
@Test func theCommandsArgumentsAndExitStatusComeThrough() throws {
    let pin = try pinnedXcode()
    let apps = try fakeXcodes(["Xcode_\(pin)": pin])
    defer { try? FileManager.default.removeItem(at: apps) }
    let run = try runPinned(
        apps: apps, command: ["/bin/sh", "-c", "printf '%s|' \"$@\"; exit 3", "sh", "two words", "-c"])
    #expect(run.status == 3)
    #expect(run.out == "two words|-c|")
}

@Test func withoutThePinnedXcodeTheCommandDoesNotRun() throws {
    let pin = try pinnedXcode()
    // A later patch release is a different Xcode, not the pinned one.
    let apps = try fakeXcodes(["Xcode": "\(pin).1"])
    defer { try? FileManager.default.removeItem(at: apps) }
    let run = try runPinned(apps: apps)
    #expect(run.status != 0)
    #expect(run.out.isEmpty, "the command ran")
    #expect(run.err.contains("Xcode \(pin)"), "\(run.err)")
    #expect(run.err.contains("\(pin).1"), "names the Xcodes it found: \(run.err)")
}
