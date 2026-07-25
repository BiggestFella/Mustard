// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mustard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "MustardKit",
            path: "Sources/MustardKit",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Mustard",
            dependencies: ["MustardKit"],
            path: "Sources/Mustard"
        ),
        .testTarget(
            name: "MustardTests",
            dependencies: ["MustardKit"],
            path: "Tests/MustardTests"
        ),
    ]
)
