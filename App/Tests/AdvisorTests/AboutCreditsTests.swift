import AppKit
import Foundation
import Testing

@testable import Advisor

// The About panel (issue #106): the standard AppKit panel showed only the name
// and version. Its credits now say what Advisor does and name the main
// components with their licences; the copyright line comes from Info.plist. The component list is written by hand, so these tests hold it to
// the sidecar's own package.json and lock file.

private func json(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repoRoot.appendingPathComponent(path))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The ranges of `text` that carry `key`, with each range's value.
private func runs(of key: NSAttributedString.Key, in text: NSAttributedString) -> [(NSRange, Any?)] {
    var found: [(NSRange, Any?)] = []
    text.enumerateAttribute(key, in: NSRange(location: 0, length: text.length)) { value, range, _ in
        found.append((range, value))
    }
    return found
}

/// The link on the first occurrence of `substring`, if the whole of it carries one.
private func link(on substring: String, in text: NSAttributedString) -> URL? {
    let range = (text.string as NSString).range(of: substring)
    guard range.location != NSNotFound else { return nil }
    var effective = NSRange()
    let value = text.attribute(.link, at: range.location, effectiveRange: &effective)
    guard NSIntersectionRange(effective, range) == range else { return nil }
    return value as? URL
}

@Test func theCreditsSayWhatAdvisorDoes() {
    #expect(AboutCredits.attributed().string.hasPrefix(AboutCredits.summary))
}

@Test func theCreditsNameEachComponentWithItsLicence() throws {
    let credits = AboutCredits.attributed()
    #expect(AboutCredits.components.map(\.name) == ["Node.js", "Claude Agent SDK", "Codex SDK"])
    for component in AboutCredits.components {
        #expect(credits.string.contains("\(component.name) — \(component.licence)"))
        // A licence that is not an open-source identifier links to its terms.
        #expect(link(on: component.licence, in: credits) == component.terms)
    }
}

/// Text with no colour of its own draws black, which is lost on the dark About
/// panel; every run must carry a colour that follows the appearance.
@Test func theCreditsTextFollowsTheAppearance() {
    for (range, colour) in runs(of: .foregroundColor, in: AboutCredits.attributed()) {
        let colour = colour as? NSColor
        #expect(colour?.type == .catalog, "run \(range) has \(String(describing: colour))")
    }
}

@Test func theCreditsNameEachDirectSidecarDependency() throws {
    let dependencies = try #require(try json("sidecar/package.json")["dependencies"] as? [String: String])
    #expect(Set(AboutCredits.components.compactMap(\.package)) == Set(dependencies.keys))
}

/// An open-source licence shows as the identifier its package declares; a
/// package that declares its own terms ("SEE LICENSE IN …") shows a link to them.
@Test func eachDependencyShowsTheLicenceItsPackageDeclares() throws {
    let packages = try #require(try json("sidecar/package-lock.json")["packages"] as? [String: Any])
    for component in AboutCredits.components {
        guard let package = component.package else { continue }
        let entry = try #require(packages["node_modules/\(package)"] as? [String: Any], "\(package) not locked")
        let declared = try #require(entry["license"] as? String, "\(package) declares no licence")
        if component.terms == nil {
            #expect(component.licence == declared, "\(package)")
        } else {
            #expect(declared.hasPrefix("SEE LICENSE IN"), "\(package) declares \(declared)")
        }
    }
}

/// The copyright line the panel shows under the credits names the holder and
/// year that LICENSE does.
@Test func theAppDeclaresTheCopyrightThatLicenseHolds() throws {
    let data = try Data(contentsOf: repoRoot.appendingPathComponent("App/Resources/Info.plist"))
    let plist = try #require(
        try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let copyright = try #require(plist["NSHumanReadableCopyright"] as? String)
    let license = try String(contentsOf: repoRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
    let line = try #require(license.split(separator: "\n").first { $0.hasPrefix("Copyright (c) ") })
    #expect(copyright.contains("Copyright © \(line.dropFirst("Copyright (c) ".count))"))
    #expect(copyright.contains("MIT licence"))
}
