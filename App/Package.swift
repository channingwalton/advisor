// swift-tools-version:6.2
import PackageDescription
import Foundation

// Derived from this file's location so the repo can move freely.
// Package.swift lives in App/; vendor/ is its sibling at the repo root.
let whisperRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()       // App/
    .deletingLastPathComponent()       // repo root
    .appendingPathComponent("vendor/whisper.cpp")
    .path

let package = Package(
    name: "Advisor",
    platforms: [.macOS(.v26)],
    targets: [
        // C shim exposing whisper.h to Swift. Headers are symlinks into vendor/whisper.cpp
        // (created by setup.sh) so the clang importer resolves everything from one flat dir.
        .target(name: "CWhisper"),
        .executableTarget(
            name: "Advisor",
            dependencies: ["CWhisper"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(whisperRoot)/build/src",
                    "-L\(whisperRoot)/build/ggml/src",
                    "-lwhisper",
                    "-Xlinker", "-rpath", "-Xlinker", "\(whisperRoot)/build/src",
                    "-Xlinker", "-rpath", "-Xlinker", "\(whisperRoot)/build/ggml/src",
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
