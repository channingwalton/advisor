import AppKit
import Testing

@testable import Advisor

private func rgb(_ color: NSColor) -> (Int, Int, Int) {
    let c = color.usingColorSpace(.sRGB)!
    return (
        Int((c.redComponent * 255).rounded()),
        Int((c.greenComponent * 255).rounded()),
        Int((c.blueComponent * 255).rounded()))
}

@Test func tagColorParsesHexPrefix() {
    #expect(rgb(Theme.nsTagColor("0x3A5CE0")) == (0x3A, 0x5C, 0xE0))
}

@Test func tagColorParsesHashPrefix() {
    #expect(rgb(Theme.nsTagColor("#2F8D5B")) == (0x2F, 0x8D, 0x5B))
}

@Test func tagColorFallsBackOnMalformed() {
    #expect(rgb(Theme.nsTagColor("not-a-colour")) == rgb(NSColor(rgb: 0x8A8B95)))
    #expect(rgb(Theme.nsTagColor("0x12")) == rgb(NSColor(rgb: 0x8A8B95)))
}

@Test func tagSwatchesAreAllParseable() {
    // Every preset swatch resolves to its literal RGB (none hit the fallback).
    for hex in Theme.tagSwatches {
        let v = UInt32(hex.dropFirst(2), radix: 16)!
        #expect(rgb(Theme.nsTagColor(hex)) == rgb(NSColor(rgb: v)))
    }
}
