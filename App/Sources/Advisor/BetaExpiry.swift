import Foundation

/// Beta time limit (issue #67). `package.sh` stamps `AdvisorBetaExpiry`
/// (packaging date + 1 month, `yyyy-MM-dd`) into the bundle's Info.plist; from
/// midnight UTC on that day the app refuses to record or talk to the AI
/// sidecar. Dev builds carry no stamp and never expire. The
/// `ADVISOR_BETA_EXPIRY` environment variable overrides the stamp so a dev
/// build can exercise the expired state.
enum BetaExpiry {
    static let infoKey = "AdvisorBetaExpiry"
    static let envKey = "ADVISOR_BETA_EXPIRY"

    /// `yyyy-MM-dd` → midnight UTC on that day. Nil for anything malformed —
    /// a bad stamp must fail open (no expiry), never brick the build.
    static func parse(_ stamp: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: stamp)
    }

    /// The effective expiry: env override first (dev testing), else the
    /// bundle stamp. Nil = no limit.
    static func expiryDate(env: [String: String], bundleStamp: String?) -> Date? {
        if let override = env[envKey], let d = parse(override) { return d }
        return bundleStamp.flatMap(parse)
    }

    static func isExpired(expiry: Date?, now: Date) -> Bool {
        guard let expiry else { return false }
        return now >= expiry
    }

    /// The user-facing notice shown wherever an action is blocked.
    static func message(expiry: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMMM yyyy"
        return "This beta expired on \(f.string(from: expiry)) — "
            + "please download the latest version."
    }

    /// The running process's expiry, read from the environment and the app
    /// bundle. Fixed at launch — the stamp can't change while running.
    static let current: Date? = expiryDate(
        env: ProcessInfo.processInfo.environment,
        bundleStamp: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)

    /// True once the beta limit has passed; the single question every gated
    /// entry point asks.
    static var expiredNow: Bool { isExpired(expiry: current, now: Date()) }

    /// The blocked-action notice, or nil while the beta is still valid.
    static var notice: String? {
        guard let current, isExpired(expiry: current, now: Date()) else { return nil }
        return message(expiry: current)
    }
}
