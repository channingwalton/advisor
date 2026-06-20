import AppKit
import SwiftUI

// The app's single design-token layer. There is no asset catalog (SwiftPM
// executable target), so semantic colours are built in code as dynamic
// NSColors that resolve light/dark from the system appearance — the app
// follows `NSApp.effectiveAppearance`. Values come straight from the handoff
// spec's "Design Tokens" + "Dark Mode" tables (design_handoff_advisor/README.md).

extension NSColor {
    /// Opaque sRGB colour from a 0xRRGGBB literal.
    convenience init(rgb hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }

    /// Dynamic colour that picks `dark` under a dark appearance, else `light`.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

private func dyn(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1)
    -> Color
{
    Color(nsColor: .dynamic(
        NSColor(rgb: light, alpha: lightAlpha), NSColor(rgb: dark, alpha: darkAlpha)))
}

enum Theme {
    // MARK: surfaces
    static let surfaceWindow = dyn(0xFBFBFD, 0x1D1D20)
    static let surfaceTitlebar = dyn(0xF8F8FB, 0x252529)
    static let surfaceCard = dyn(0xFFFFFF, 0x2B2B30)
    /// Follow-up input fill and other inset wells inside a card.
    static let surfaceCardInset = dyn(0xF7F7FA, 0x202024)
    /// Toolbar control fill (record cluster, source button, float).
    static let surfaceControl = dyn(0xFFFFFF, 0x323237)

    // MARK: borders
    static let hairline = dyn(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.13)
    static let hairlineStrong = dyn(0x000000, 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.16)

    // MARK: text
    static let textStrong = dyn(0x2A2B33, 0xF2F2F6)
    static let textBody = dyn(0x3A3B44, 0xDCDDE3)
    static let textSecondary = dyn(0x5E5F69, 0xA6A7B0)
    static let textTertiary = dyn(0x8A8B95, 0x8C8D97)
    static let textMuted = dyn(0xAEAFB8, 0x6F7079)
    /// NSColor twin of `textBody`, for the AppKit-backed transcript text view.
    static let nsTextBody = NSColor.dynamic(NSColor(rgb: 0x3A3B44), NSColor(rgb: 0xDCDDE3))

    // MARK: accent (blue)
    static let accent = dyn(0x3A5CE0, 0x6E8BFF)
    static let accentHover = dyn(0x3350CF, 0x829BFF)
    static let accentTint = dyn(0xEEF1FB, 0x6E8BFF, darkAlpha: 0.16)
    static let accentTintStrong = dyn(0xE7ECFD, 0x6E8BFF, darkAlpha: 0.20)
    /// White glyphs/text on a filled accent button stay white in both modes.
    static let onAccent = Color.white

    // MARK: record (red)
    static let recordRed = dyn(0xFF453A, 0xFF5F55)
    static let recordRedText = dyn(0xD8362D, 0xFF8077)

    // MARK: context (violet)
    static let contextViolet = dyn(0x6044C0, 0xB9A4FF)
    static let contextTint = dyn(0xEEE9FB, 0xB9A4FF, darkAlpha: 0.16)
    static let contextCodeBg = dyn(0xF1F0F6, 0xB9A4FF, darkAlpha: 0.14)
    static let contextCodeText = dyn(0x6E54B8, 0xCCBEFF)

    // MARK: fact-check verdicts
    static let factGreen = dyn(0x2F8D5B, 0x46D389)
    static let factGreenTint = dyn(0xE6F4EC, 0x46D389, darkAlpha: 0.16)
    static let factAmber = dyn(0xA06A12, 0xECB845)
    static let factAmberTint = dyn(0xFAF0DB, 0xECB845, darkAlpha: 0.16)
    static let factRed = dyn(0xC0392B, 0xFF6B5C)
    static let factRedTint = dyn(0xFBE9E7, 0xFF6B5C, darkAlpha: 0.16)

    // MARK: misc
    static let termHighlightBg = dyn(0xEAE6FB, 0xB9A4FF, darkAlpha: 0.22)
    static let termHighlightText = dyn(0x6044C0, 0xCCBEFF)
    static let liveGreen = dyn(0x54A85E, 0x5FD07A)

    // MARK: metrics
    enum Metric {
        static let toolbarHeight: CGFloat = 60
        static let contentMaxWidth: CGFloat = 812
        static let contentTopPad: CGFloat = 26
        static let contentSidePad: CGFloat = 28
        static let contentBottomPad: CGFloat = 40

        static let cardRadius: CGFloat = 14
        static let inputRadius: CGFloat = 12
        static let buttonRadius: CGFloat = 9
        static let chipRadius: CGFloat = 14
        static let pillRadius: CGFloat = 6

        static let paragraphSpacing: CGFloat = 6
        static let transcriptSize: CGFloat = 14.5
        static let transcriptLineSpacing: CGFloat = 14.5 * 0.2  // line-height 1.2
        static let cardBodySize: CGFloat = 13.5
    }

    /// Card ambient shadow. Near-invisible in dark mode, where the elevated
    /// card surface + hairline border carry the separation instead.
    static let cardShadow = dyn(0x141628, 0x000000, lightAlpha: 0.14, darkAlpha: 0.35)

    // MARK: tags (issue #15)

    /// Preset tag swatches — distinct, theme-aligned hues stored as `0xRRGGBB`.
    /// A tag colour is a single value (not a light/dark pair); the pill fills it
    /// at low opacity so it reads in both appearances. The default for a new tag
    /// is the first entry.
    static let tagSwatches: [String] = [
        "0x3A5CE0", "0x6044C0", "0x2F8D5B", "0xA06A12",
        "0xC0392B", "0x0E7C86", "0xB03A78", "0x556070",
    ]

    /// Parse a stored tag hex (`0xRRGGBB` or `#RRGGBB`) to an NSColor, falling
    /// back to a neutral grey when the string is malformed.
    static func nsTagColor(_ hex: String) -> NSColor {
        var s = Substring(hex)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = s.dropFirst(2) }
        else if s.hasPrefix("#") { s = s.dropFirst(1) }
        if s.count == 6, let v = UInt32(s, radix: 16) { return NSColor(rgb: v) }
        return NSColor(rgb: 0x8A8B95)
    }
}

extension Color {
    /// A tag colour from its stored `0xRRGGBB`/`#RRGGBB` hex (issue #15).
    init(tagHex hex: String) { self = Color(nsColor: Theme.nsTagColor(hex)) }
}
