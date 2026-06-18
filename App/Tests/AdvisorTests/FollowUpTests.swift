import Testing
import Foundation

@testable import Advisor

@Test func followUpBlockIsBlockquoteCard() {
    let asked = Date(timeIntervalSince1970: 1_000)
    let block = SessionMarkdown.followUpBlock(
        question: "What did we decide?", answer: "We chose tiered pricing.", asked: asked)

    #expect(block.contains("> **Q · What did we decide?**"))
    #expect(block.contains("> We chose tiered pricing."))
    #expect(block.contains("_Asked "))
    // Every line stays in the blockquote.
    #expect(block.split(separator: "\n").allSatisfy { $0.hasPrefix(">") })
}

@Test func followUpBlockKeepsMultilineAnswerInQuote() {
    let block = SessionMarkdown.followUpBlock(
        question: "q", answer: "line one\n\nline two", asked: Date(timeIntervalSince1970: 0))
    #expect(block.contains("> line one"))
    #expect(block.contains("> line two"))
    #expect(block.split(separator: "\n").allSatisfy { $0.hasPrefix(">") })
}

@Test func appendAddsFollowUpsHeadingOnce() {
    let existing = "---\nstarted: x\n---\n\n# Transcript\n\n- 17:00:00 hello\n"
    let once = SessionArchive.appendingFollowUp(
        to: existing, question: "q1", answer: "a1", asked: Date(timeIntervalSince1970: 0))
    let twice = SessionArchive.appendingFollowUp(
        to: once, question: "q2", answer: "a2", asked: Date(timeIntervalSince1970: 0))

    // Heading appears exactly once across repeated appends.
    #expect(twice.components(separatedBy: "# Follow-ups").count - 1 == 1)
    // Both Q&As are present.
    #expect(twice.contains("> **Q · q1**"))
    #expect(twice.contains("> **Q · q2**"))
    // The original transcript is preserved.
    #expect(twice.contains("- 17:00:00 hello"))
}

@Test func appendSeparatesFromContentWithoutTrailingNewline() {
    let existing = "# Transcript\n\n- 17:00:00 hello" // no trailing newline
    let out = SessionArchive.appendingFollowUp(
        to: existing, question: "q", answer: "a", asked: Date(timeIntervalSince1970: 0))
    // The heading must not glue onto the last transcript line.
    #expect(!out.contains("hello# Follow-ups"))
    #expect(out.contains("hello\n"))
}
