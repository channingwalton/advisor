import Foundation
import Testing

@testable import Advisor

// package.sh bundles the sidecar's node_modules, and a package that ships with
// no licence file would go out without the text its licence asks copies to
// carry (three did: @openai/codex, its darwin-arm64 binary and standardwebhooks).
// App/licences.sh copies the texts sidecar/licences/ supplies into their
// packages, then fails the package, naming them, if any package still has none.

/// A folder holding `files` (relative path → contents).
private func tree(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("advisor-licences-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (path, contents) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

/// Runs App/licences.sh over a node_modules folder and a supplements folder.
private func runLicences(modules: URL, supplements: URL) throws -> (status: Int32, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [repoRoot.appendingPathComponent("App/licences.sh").path, modules.path, supplements.path]
    let err = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = err
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

private func contents(_ dir: URL, _ path: String) -> String? {
    try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
}

@Test func aTreeWhosePackagesEachCarryALicencePasses() throws {
    let modules = try tree([
        "a/package.json": "{}", "a/LICENSE": "",
        "@s/b/package.json": "{}", "@s/b/LICENCE.md": "",
        "c/package.json": "{}", "c/license-mit.txt": "",
        "d/package.json": "{}", "d/COPYING": "",
        "e/package.json": "{}", "e/UNLICENSE": "",
        "a/node_modules/f/package.json": "{}", "a/node_modules/f/License": "",
        // Not packages: npm's bin links and a scope folder's own files.
        ".bin/a": "", "@s/.DS_Store": "",
    ])
    let supplements = try tree([:])
    defer { for dir in [modules, supplements] { try? FileManager.default.removeItem(at: dir) } }
    let run = try runLicences(modules: modules, supplements: supplements)
    #expect(run.status == 0, "\(run.err)")
}

@Test func eachPackageWithNoLicenceFailsThePackageByName() throws {
    let modules = try tree([
        "a/package.json": "{}", "a/LICENSE": "",
        "@s/b/package.json": "{}", "@s/b/README.md": "",
        "a/node_modules/c/package.json": "{}",
    ])
    let supplements = try tree([:])
    defer { for dir in [modules, supplements] { try? FileManager.default.removeItem(at: dir) } }
    let run = try runLicences(modules: modules, supplements: supplements)
    #expect(run.status != 0)
    #expect(run.err.contains("@s/b"))
    #expect(run.err.contains("a/node_modules/c"))
    #expect(!run.err.contains("no licence file in a\n"))
}

@Test func aSuppliedLicenceIsCopiedIntoItsPackage() throws {
    // @s/b already has a vendor/ folder, which the supplied one merges into.
    let modules = try tree(["@s/b/package.json": "{}", "@s/b/vendor/bin": "", "c/package.json": "{}"])
    let supplements = try tree([
        "README.md": "where the texts come from",
        "@s/b/LICENSE": "Apache", "@s/b/NOTICE": "notice", "@s/b/vendor/tool.LICENSE": "tool",
        "c/LICENSE": "MIT",
    ])
    defer { for dir in [modules, supplements] { try? FileManager.default.removeItem(at: dir) } }
    let run = try runLicences(modules: modules, supplements: supplements)
    #expect(run.status == 0, "\(run.err)")
    #expect(contents(modules, "@s/b/LICENSE") == "Apache")
    #expect(contents(modules, "@s/b/NOTICE") == "notice")
    #expect(contents(modules, "@s/b/vendor/tool.LICENSE") == "tool")
    #expect(contents(modules, "c/LICENSE") == "MIT")
}

/// A package that starts to ship its own licence keeps it, and the supplied one
/// is reported as no longer needed rather than failing a release. The texts
/// for programs the package bundles (`<program>.LICENSE`) are still copied:
/// the package's own licence does not cover them.
@Test func aSupplyForAPackageWithItsOwnLicenceLeavesItAlone() throws {
    let modules = try tree(["a/package.json": "{}", "a/LICENSE": "own"])
    let supplements = try tree(["a/LICENSE": "supplied", "a/zsh.LICENSE": "zsh"])
    defer { for dir in [modules, supplements] { try? FileManager.default.removeItem(at: dir) } }
    let run = try runLicences(modules: modules, supplements: supplements)
    #expect(run.status == 0, "\(run.err)")
    #expect(contents(modules, "a/LICENSE") == "own")
    #expect(contents(modules, "a/zsh.LICENSE") == "zsh")
    #expect(run.err.contains("warning: a ships its own licence"))
}

@Test func anEmptySupplyFolderChangesNothing() throws {
    let modules = try tree(["a/package.json": "{}", "a/LICENSE": "own"])
    let supplements = try tree([:])
    try FileManager.default.createDirectory(
        at: supplements.appendingPathComponent("a"), withIntermediateDirectories: true)
    defer { for dir in [modules, supplements] { try? FileManager.default.removeItem(at: dir) } }
    let run = try runLicences(modules: modules, supplements: supplements)
    #expect(run.status == 0, "\(run.err)")
    #expect(try FileManager.default.contentsOfDirectory(atPath: modules.appendingPathComponent("a").path).sorted()
        == ["LICENSE", "package.json"])
}

/// A bundled program's text is not the package's own licence.
@Test func aProgramLicenceAloneLeavesThePackageUnlicensed() throws {
    let modules = try tree(["a/package.json": "{}"])
    let supplements = try tree(["a/zsh.LICENSE": "zsh"])
    defer { for dir in [modules, supplements] { try? FileManager.default.removeItem(at: dir) } }
    let run = try runLicences(modules: modules, supplements: supplements)
    #expect(run.status != 0)
    #expect(run.err.contains("no licence file in a"))
    #expect(!run.err.contains("warning"))
}

@Test func aSupplyForAPackageThatIsNotBundledIsReported() throws {
    let modules = try tree(["a/package.json": "{}", "a/LICENSE": ""])
    let supplements = try tree(["@s/gone/LICENSE": "MIT"])
    defer { for dir in [modules, supplements] { try? FileManager.default.removeItem(at: dir) } }
    let run = try runLicences(modules: modules, supplements: supplements)
    #expect(run.status == 0, "\(run.err)")
    #expect(run.err.contains("warning: @s/gone is not bundled"))
    #expect(!FileManager.default.fileExists(atPath: modules.appendingPathComponent("@s/gone").path))
}

/// The repo's own supplies are each for a package the sidecar locks, under
/// the licence that package declares.
@Test func eachRepoSupplyIsForALockedPackage() throws {
    let supplements = repoRoot.appendingPathComponent("sidecar/licences")
    let lock = try Data(contentsOf: repoRoot.appendingPathComponent("sidecar/package-lock.json"))
    let packages = try #require(
        (try JSONSerialization.jsonObject(with: lock) as? [String: Any])?["packages"] as? [String: Any])
    let fm = FileManager.default
    var supplied: [String] = []
    for entry in try fm.contentsOfDirectory(atPath: supplements.path).sorted() {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: supplements.appendingPathComponent(entry).path, isDirectory: &isDir),
            isDir.boolValue
        else { continue }
        supplied += entry.hasPrefix("@")
            ? try fm.contentsOfDirectory(atPath: supplements.appendingPathComponent(entry).path)
                .filter { !$0.hasPrefix(".") }.map { "\(entry)/\($0)" }
            : [entry]
    }
    #expect(Set(supplied) == ["@openai/codex", "@openai/codex-darwin-arm64", "standardwebhooks"])
    for name in supplied {
        let entry = packages["node_modules/\(name)"] as? [String: Any]
        #expect(entry != nil, "\(name) is not in the lock file")
        let licence = try String(
            contentsOf: supplements.appendingPathComponent("\(name)/LICENSE"), encoding: .utf8)
        switch entry?["license"] as? String {
        case "Apache-2.0": #expect(licence.contains("Apache License"), "\(name)")
        case "MIT": #expect(licence.contains("MIT License"), "\(name)")
        case let other: Issue.record("\(name) declares \(String(describing: other)); check its supplied text")
        }
    }
}
