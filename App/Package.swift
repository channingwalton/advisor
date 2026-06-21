// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Advisor",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Advisor",
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
        .testTarget(
            name: "AdvisorTests",
            dependencies: ["Advisor"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
