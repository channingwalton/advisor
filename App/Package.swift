// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Advisor",
    platforms: [.macOS(.v26)],
    dependencies: [
        // GitHub-flavoured markdown renderer for card bodies (tables, lists,
        // headings, code blocks) — SwiftUI's Text only does inline markdown.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "Advisor",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    // Embed Info.plist (mic usage description) into the bare executable.
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
    ]
)
