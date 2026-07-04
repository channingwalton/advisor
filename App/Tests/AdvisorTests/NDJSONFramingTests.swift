import Foundation
import Testing

@testable import Advisor

// SidecarManager.consume frames NDJSON off a byte stream that splits arbitrarily.
// Pin the pure splitter (issue #65).

private func d(_ s: String) -> Data { Data(s.utf8) }
private func s(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

@Test func ndjsonSplitsMultipleFramesPerChunk() {
    let (frames, rest) = SidecarManager.ndjsonFrames(d("{\"a\":1}\n{\"b\":2}\n"))
    #expect(frames.map(s) == ["{\"a\":1}", "{\"b\":2}"])
    #expect(rest.isEmpty)
}

@Test func ndjsonHoldsAPartialTrailingLine() {
    let (frames, rest) = SidecarManager.ndjsonFrames(d("{\"a\":1}\n{\"b\""))
    #expect(frames.map(s) == ["{\"a\":1}"])
    #expect(s(rest) == "{\"b\"") // carried to the next chunk
}

@Test func ndjsonAssemblesAcrossChunks() {
    // First chunk leaves a partial line; appending the rest completes it.
    let (_, rest1) = SidecarManager.ndjsonFrames(d("{\"a\":1}\n{\"b\""))
    let (frames, rest2) = SidecarManager.ndjsonFrames(rest1 + d(":2}\n"))
    #expect(frames.map(s) == ["{\"b\":2}"])
    #expect(rest2.isEmpty)
}

@Test func ndjsonWithNoNewlineYieldsNoFrames() {
    let (frames, rest) = SidecarManager.ndjsonFrames(d("{\"a\":1}"))
    #expect(frames.isEmpty)
    #expect(s(rest) == "{\"a\":1}")
}

@Test func ndjsonYieldsEmptyFramesForBlankLines() {
    // consume filters empties; the splitter still reports them faithfully.
    let (frames, rest) = SidecarManager.ndjsonFrames(d("\n\n"))
    #expect(frames.count == 2)
    #expect(frames.allSatisfy { $0.isEmpty })
    #expect(rest.isEmpty)
}
