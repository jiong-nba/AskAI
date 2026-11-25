// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AskAI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AskAI"),
        .testTarget(name: "AskAITests", dependencies: ["AskAI"]),
    ]
)
