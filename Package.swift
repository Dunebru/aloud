// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Aloud",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendored copy of FluidAudio v0.15.7 (Apache 2.0). The NemoTextProcessing xcframework it
        // needs is fetched by scripts/fetch-deps.sh into Vendor/FluidAudio/Binaries (gitignored).
        .package(path: "Vendor/FluidAudio"),
    ],
    targets: [
        .executableTarget(
            name: "Aloud",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Aloud",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "AloudTests", dependencies: ["Aloud"], path: "Tests/AloudTests", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
