import Testing

@testable import Advisor

// Issue #124: a follow-up that was not sent cleared the card's reply field.

@Test func aSentFollowUpClearsTheField() {
    var draft = ReplyDraft(text: "  What did she mean?  ")
    var sent: [String] = []
    draft.submit { sent.append($0); return true }
    #expect(sent == ["What did she mean?"])
    #expect(draft.text.isEmpty)
}

@Test func aFollowUpThatIsNotSentStaysInTheField() {
    var draft = ReplyDraft(text: "What did she mean?")
    draft.submit { _ in false }
    #expect(draft.text == "What did she mean?")
    #expect(draft.canSend)
}

@Test func anEmptyFollowUpIsNotSubmitted() {
    var draft = ReplyDraft(text: "   ")
    var calls = 0
    draft.submit { _ in calls += 1; return true }
    #expect(calls == 0)
    #expect(!draft.canSend)
    #expect(draft.text == "   ")
}
