// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "parrot",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "TOMLDecoder", package: "TOMLDecoder"),
            ],
            linkerSettings: [
                // SwiftPM stamps the SDK version in LC_BUILD_VERSION as the
                // deployment target, so the binary claims it was built against
                // the macOS 14 SDK. AppKit reads that to decide which design
                // system to serve, and hands a pre-Tahoe app the old switches
                // and sliders. Say 26 so Liquid Glass applies on Tahoe while
                // the deployment target stays at 14.
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "macos",
                    "-Xlinker", "14.0",
                    "-Xlinker", "26.0",
                ])
            ]
        ),
        .testTarget(
            name: "parrotTests",
            dependencies: ["parrot"]
        ),
    ]
)
