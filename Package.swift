// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MiniDictate",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "MiniDictate",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        ),
    ]
)
