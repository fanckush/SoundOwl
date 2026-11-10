// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundOwl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SoundOwlCore", targets: ["SoundOwlCore"]),
        .library(name: "SoundOwlCLI", targets: ["SoundOwlCLI"]),
        .library(name: "SoundOwlLive", targets: ["SoundOwlLive"]),
        .executable(name: "soundowl", targets: ["soundowl"]),
        .executable(name: "soundowl-dev", targets: ["soundowl-dev"])
    ],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "SoundOwlCore",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]
        ),
        // The `soundowl` command line. The app links it too: SoundOwl.app/Contents/Resources/soundowl
        // runs the app's own executable with --cli, so the shipped tool adds no second copy of ORT.
        .target(
            name: "SoundOwlCLI",
            dependencies: ["SoundOwlCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "soundowl", dependencies: ["SoundOwlCLI"]),
        // Restoring other apps' audio as it plays: Core Audio process taps around a LivePipeline.
        .target(name: "SoundOwlLive", dependencies: ["SoundOwlCore"]),
        // Developer harness for parity checks, benchmarks and the live feasibility test. Never shipped.
        .executableTarget(name: "soundowl-dev", dependencies: ["SoundOwlCore", "SoundOwlLive"]),
        .testTarget(name: "SoundOwlCoreTests", dependencies: ["SoundOwlCore", "SoundOwlCLI", "SoundOwlLive"])
    ]
)
