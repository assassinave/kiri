// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "kiri",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "KiriCore"),
        .executableTarget(name: "kiri", dependencies: ["KiriCore"]),
        .testTarget(name: "KiriCoreTests", dependencies: ["KiriCore"]),
    ],
    swiftLanguageModes: [.v5]
)
