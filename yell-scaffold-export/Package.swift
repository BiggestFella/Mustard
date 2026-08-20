// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Yell",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "YellKit",
            path: "Sources/YellKit"
        ),
        .executableTarget(
            name: "Yell",
            dependencies: ["YellKit"],
            path: "Sources/Yell"
        ),
        .testTarget(
            name: "YellTests",
            dependencies: ["YellKit"],
            path: "Tests/YellTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
