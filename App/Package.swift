// swift-tools-version:5.10
import PackageDescription

// Adjust if the repo moves.
let whisperRoot = "/Users/channing/dev/advisor/Advisor/vendor/whisper.cpp"

let package = Package(
    name: "Advisor",
    platforms: [.macOS(.v14)],
    targets: [
        // C shim exposing whisper.h to Swift. Headers are symlinks into vendor/whisper.cpp
        // (created by setup.sh) so the clang importer resolves everything from one flat dir.
        .target(name: "CWhisper"),
        .executableTarget(
            name: "Advisor",
            dependencies: ["CWhisper"],
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
