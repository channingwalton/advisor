import Testing

@testable import Advisor

// Recognised text reaches the log file only when the `logTranscriptText`
// preference is on (code review 2026-10-17): the log is diagnostics, the
// transcripts live in the session folder the user chose. Off, the line still
// records that an utterance arrived, and its length, so timing and echo
// behaviour stay diagnosable.

@Test func utteranceLogLineOmitsTheTextByDefault() {
    let line = Recorder.utteranceLogLine("apple(me)", "the quarterly numbers", includeText: false)
    #expect(!line.contains("quarterly"))
    #expect(line == "[advisor] apple(me): 21 chars")
}

@Test func utteranceLogLineIncludesTheTextWhenAsked() {
    let line = Recorder.utteranceLogLine("echo suppressed", "the quarterly numbers", includeText: true)
    #expect(line == "[advisor] echo suppressed: \"the quarterly numbers\"")
}

