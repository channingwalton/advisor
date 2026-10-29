import AppKit
import SwiftUI

/// The About panel's credits (issue #106): what Advisor does, and the main
/// components it ships with their licences. The standard panel shows them under
/// the name and version, and the copyright line from `NSHumanReadableCopyright`
/// in Info.plist below them. The list stops at the runtime and the sidecar's
/// direct dependencies: the hundred-odd packages that ship would bury the rest.
enum AboutCredits {
    struct Component: Equatable {
        let name: String
        /// The npm package the sidecar depends on; nil for the Node.js runtime.
        let package: String?
        let licence: String
        /// Where the terms are, for a licence that is not an open-source identifier.
        let terms: URL?
    }

    static let summary =
        "Listens to your conversations, transcribes them on your Mac, and surfaces answers, context and fact-checks as you talk."

    static let components = [
        Component(name: "Node.js", package: nil, licence: "MIT", terms: nil),
        // Its package declares "SEE LICENSE IN README.md"; the licence file
        // points at these agreements.
        Component(
            name: "Claude Agent SDK", package: "@anthropic-ai/claude-agent-sdk", licence: "Anthropic terms",
            terms: URL(string: "https://code.claude.com/docs/en/legal-and-compliance")),
        Component(name: "Codex SDK", package: "@openai/codex-sdk", licence: "Apache-2.0", terms: nil),
    ]

    /// The credits as the panel shows them: small, centred, in colours that
    /// follow the appearance (plain text would draw black on the dark panel).
    static func attributed() -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred,
        ]
        let text = NSMutableAttributedString()
        func add(_ string: String, _ extra: [NSAttributedString.Key: Any] = [:]) {
            text.append(NSAttributedString(string: string, attributes: body.merging(extra) { $1 }))
        }
        add(summary + "\n\n")
        add("Acknowledgements", [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
        for component in components {
            add("\n\(component.name) — ")
            add(component.licence, component.terms.map { [.link: $0] } ?? [:])
        }
        return text
    }
}

/// Replaces the menu's "About Advisor", which would open the panel with the
/// name and version only, with one that adds the credits.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Advisor") {
                NSApp.orderFrontStandardAboutPanel(options: [.credits: AboutCredits.attributed()])
            }
        }
    }
}
