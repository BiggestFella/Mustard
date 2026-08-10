// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mustard",
    platforms: [.macOS(.v26)],
    targets: [
        // Objective-C micro-target: catches NSExceptions that Apple frameworks
        // (AVFAudio) raise, which Swift cannot catch and which corrupt the
        // Swift-concurrency runtime if they unwind through async frames.
        .target(
            name: "MustardShims",
            path: "Sources/MustardShims"
        ),
        .target(
            name: "MustardKit",
            dependencies: ["MustardShims"],
            path: "Sources/MustardKit",
            resources: [
                .process("Resources"),
                .process("Agent/Prompts"),
                .process("Voice/Prompts"),
            ]
        ),
        .executableTarget(
            name: "Mustard",
            dependencies: ["MustardKit"],
            path: "Sources/Mustard"
        ),
        .testTarget(
            name: "MustardTests",
            dependencies: ["MustardKit", "MustardShims"],
            path: "Tests/MustardTests"
        ),
    ],
    // Tools 6.x defaults new packages to the Swift 6 language mode; stay in the
    // mode the codebase was written for until a deliberate migration.
    swiftLanguageModes: [.v5]
)
