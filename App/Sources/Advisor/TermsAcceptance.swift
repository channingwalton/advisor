import Foundation

/// First-run terms acceptance. The app presents TERMS.md (bundled by
/// package.sh, repo root in a dev checkout) in a blocking sheet until the
/// current version has been accepted; the accepted version persists in
/// config.json. Declining quits the app. Bump `currentVersion` in step with a
/// material TERMS.md change to re-present the sheet.
enum TermsAcceptance {
    /// Must match the "Version" line at the top of TERMS.md.
    static let currentVersion = "1.0"

    static func needsAcceptance(accepted: String) -> Bool {
        accepted != currentVersion
    }

    /// Whether the sheet must be shown now. Reads config each call, so the
    /// gated entry points (record, resume, query) unblock as soon as the
    /// sheet's Accept persists.
    static var needed: Bool {
        needsAcceptance(accepted: AdvisorConfig.load().acceptedTermsVersion)
    }

    /// The blocked-action notice, or nil once accepted.
    static var notice: String? {
        needed ? "Please accept the terms of use first." : nil
    }

    static func accept() {
        var c = AdvisorConfig.load()
        c.acceptedTermsVersion = currentVersion
        c.save()
    }

    /// The full terms markdown for the sheet. The fallback keeps the sheet
    /// functional (and acceptance meaningful) if the file is missing.
    static func text() -> String {
        (try? String(contentsOf: AppResources.termsURL, encoding: .utf8))
            ?? "Terms unavailable in this build — the current terms are TERMS.md "
            + "in the Advisor source repository."
    }
}
