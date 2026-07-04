import Foundation
import Testing

@testable import Advisor

// The beta expiry gate (issue #67): packaged betas carry an AdvisorBetaExpiry
// date; from that day the app blocks recording and all AI interaction.

@Test func parsesAStampedExpiryDateAsUTCMidnight() {
    let d = BetaExpiry.parse("2026-08-04")
    #expect(d == Date(timeIntervalSince1970: 1_785_801_600)) // 2026-08-04T00:00:00Z
}

@Test func rejectsMalformedStamps() {
    #expect(BetaExpiry.parse("") == nil)
    #expect(BetaExpiry.parse("next month") == nil)
    #expect(BetaExpiry.parse("04/08/2026") == nil)
}

@Test func expiryBoundaryIsMidnightOnTheStampedDay() {
    let expiry = BetaExpiry.parse("2026-08-04")!
    #expect(!BetaExpiry.isExpired(expiry: expiry, now: expiry.addingTimeInterval(-1)))
    #expect(BetaExpiry.isExpired(expiry: expiry, now: expiry))
    #expect(BetaExpiry.isExpired(expiry: expiry, now: expiry.addingTimeInterval(1)))
}

@Test func noStampMeansNoExpiry() {
    // Dev builds have no Info.plist stamp — they never expire.
    #expect(!BetaExpiry.isExpired(expiry: nil, now: .distantFuture))
}

@Test func envOverrideBeatsTheBundleStamp() {
    // ADVISOR_BETA_EXPIRY lets a dev build exercise the expired state.
    let d = BetaExpiry.expiryDate(
        env: ["ADVISOR_BETA_EXPIRY": "2000-01-01"], bundleStamp: "2026-08-04")
    #expect(d == BetaExpiry.parse("2000-01-01"))
}

@Test func bundleStampAppliesWhenNoEnvOverride() {
    let d = BetaExpiry.expiryDate(env: [:], bundleStamp: "2026-08-04")
    #expect(d == BetaExpiry.parse("2026-08-04"))
}

@Test func noSourcesMeansNoExpiryDate() {
    #expect(BetaExpiry.expiryDate(env: [:], bundleStamp: nil) == nil)
}

@Test func expiredMessageNamesTheDateAndTheSite() {
    let msg = BetaExpiry.message(expiry: BetaExpiry.parse("2026-08-04")!)
    #expect(msg.contains("4 August 2026"))
    #expect(msg.lowercased().contains("beta"))
}

@Test func onlyStopAndConfigMessagesPassAfterExpiry() {
    // Cancel/end/config must survive expiry (they stop existing AI work);
    // everything that initiates or feeds AI must not.
    #expect(SidecarManager.allowedAfterExpiry("cancel"))
    #expect(SidecarManager.allowedAfterExpiry("session_end"))
    #expect(SidecarManager.allowedAfterExpiry("config"))
    for blocked in [
        "session_start", "session_context", "utterance", "note", "query",
        "summarise_live", "ask_document", "summarise_document", "card_reply",
    ] {
        #expect(!SidecarManager.allowedAfterExpiry(blocked))
    }
}
