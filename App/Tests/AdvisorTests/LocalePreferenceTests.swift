import Foundation
import Testing

@testable import Advisor

@Test func configDefaultsSttLocaleToSystem() {
    // "" is the sentinel meaning "follow the device default locale".
    #expect(AdvisorConfig().sttLocale == "")
}

@Test func configDecodesMissingSttLocaleAsSystem() throws {
    let json = Data("{}".utf8)
    let config = try JSONDecoder().decode(AdvisorConfig.self, from: json)
    #expect(config.sttLocale == "")
}

@Test func configRoundTripsExplicitSttLocale() throws {
    var config = AdvisorConfig()
    config.sttLocale = "fr_FR"
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AdvisorConfig.self, from: data)
    #expect(decoded.sttLocale == "fr_FR")
}
