import Foundation
import Testing

@testable import Advisor

// First-run terms acceptance: the app presents TERMS.md until the current
// version has been accepted, persisting the accepted version in config.json.

@Test func termsNeededWhenNothingAccepted() {
    #expect(TermsAcceptance.needsAcceptance(accepted: ""))
}

@Test func termsNeededWhenAnOlderVersionWasAccepted() {
    #expect(TermsAcceptance.needsAcceptance(accepted: "0.9"))
}

@Test func termsNotNeededOnceCurrentVersionAccepted() {
    #expect(!TermsAcceptance.needsAcceptance(accepted: TermsAcceptance.currentVersion))
}

@Test func termsTextLoadsFromTheRepoInADevCheckout() {
    // AppResources falls back to the repo root's TERMS.md when unbundled; the
    // packaged app carries a copy (package.sh). The version constant must match
    // the document being shown.
    let text = TermsAcceptance.text()
    #expect(text.contains("Advisor — Terms of Use"))
    #expect(text.contains("Version \(TermsAcceptance.currentVersion)"))
}

@Test func websiteTermsPageStaysInStepWithTheAcceptedVersion() throws {
    // www/terms.html duplicates TERMS.md for the site; a material change must
    // bump the version in both and in TermsAcceptance.currentVersion.
    let page = try String(
        contentsOf: repoRoot.appendingPathComponent("www/terms.html"), encoding: .utf8)
    #expect(page.contains("Version \(TermsAcceptance.currentVersion)"))
}

@Test func acceptedTermsVersionRoundTripsThroughConfig() throws {
    var c = AdvisorConfig()
    #expect(c.acceptedTermsVersion == "")     // default: not accepted
    c.acceptedTermsVersion = "1.0"
    let decoded = try JSONDecoder().decode(
        AdvisorConfig.self, from: JSONEncoder().encode(c))
    #expect(decoded.acceptedTermsVersion == "1.0")
}

@Test func acceptedTermsVersionDefaultsWhenAbsentFromDisk() throws {
    // A pre-terms config.json must decode as "not accepted", not throw.
    let json = Data(#"{"provider":"claude"}"#.utf8)
    let c = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(c.acceptedTermsVersion == "")
}
