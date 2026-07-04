import Testing

@testable import Advisor

// The echo-dedup helpers are pure; pin the thresholds/boundaries they encode
// (issue #65). pairMatch is the seam the retroactive-cleanup path also depends on.

@Test func tokensLowercasesAndSplitsOnNonAlphanumerics() {
    #expect(Recorder.tokens("Hello, WORLD! it's 42.") == ["hello", "world", "it", "s", "42"])
    #expect(Recorder.tokens("   ") == [])
}

@Test func distinctiveKeepsOnlyWordsLongerThanThree() {
    // Stopword-length words (≤3 chars) are dropped so they don't inflate matches.
    #expect(Recorder.distinctive(["the", "cat", "sat", "effect", "systems"]) == ["effect", "systems"])
}

@Test func isJunkFlagsNonSpeechArtefacts() {
    #expect(Recorder.isJunk("[BLANK_AUDIO]"))
    #expect(Recorder.isJunk("*Bell rings*"))
    #expect(Recorder.isJunk("(claps)"))
    #expect(Recorder.isJunk("..."))          // no alphanumerics
    #expect(!Recorder.isJunk("hello there"))  // real speech
    #expect(!Recorder.isJunk("chapter (one)")) // alphanumeric, not bracket-wrapped
}

@Test func pairMatchNeedsSeventyPercentOverlap() {
    let a: Set<String> = ["effect", "systems", "ocaml", "handlers"] // 4
    #expect(Recorder.pairMatch(a, ["effect", "systems", "ocaml", "monads"]))   // 3/4 = 0.75 ≥ 0.7
    #expect(!Recorder.pairMatch(a, ["effect", "systems", "python", "monads"])) // 2/4 = 0.5 < 0.7
}

@Test func pairMatchUsesMinLengthBasis() {
    // Tolerant of differing segment lengths: 3 shared over the shorter (3-word)
    // side matches even though it's only 3/5 of the longer side.
    let long: Set<String> = ["effect", "systems", "ocaml", "handlers", "typed"] // 5
    #expect(Recorder.pairMatch(long, ["effect", "systems", "ocaml"]))           // 3/min(5,3) = 1.0
}

@Test func pairMatchIsEmptySafe() {
    #expect(!Recorder.pairMatch([], ["effect"]))
    #expect(!Recorder.pairMatch(["effect"], []))
}
