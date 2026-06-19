import Testing

@testable import Advisor

@Test func noAgentsClosesImmediately() {
    // The prompt never appears when nothing is running, whatever the choice.
    #expect(SessionClose.action(agentsInFlight: false, choice: .wait) == .closeNow)
    #expect(SessionClose.action(agentsInFlight: false, choice: .terminate) == .closeNow)
    #expect(SessionClose.action(agentsInFlight: false, choice: .cancel) == .closeNow)
}

@Test func waitChoiceWaitsThenCloses() {
    #expect(SessionClose.action(agentsInFlight: true, choice: .wait) == .waitThenClose)
}

@Test func terminateChoiceStopsThenCloses() {
    #expect(SessionClose.action(agentsInFlight: true, choice: .terminate) == .terminateAndClose)
}

@Test func cancelChoiceKeepsWindowOpen() {
    #expect(SessionClose.action(agentsInFlight: true, choice: .cancel) == .stayOpen)
}
