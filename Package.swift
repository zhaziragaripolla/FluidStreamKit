// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode turns on *complete* strict concurrency checking, which is what
// `.enableExperimentalFeature("StrictConcurrency")` did under Swift 5 mode. So the flag is
// left out here on purpose. The stricter checks below are upcoming features that Swift 6
// mode does not enable by default.
let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "FluidStreamKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),        // host-side `swift test`
        .macCatalyst(.v17),
    ],
    products: [
        .library(name: "FluidStreamCore", targets: ["FluidStreamCore"]),
        .library(name: "FluidStreamParser", targets: ["FluidStreamParser"]),
        .library(name: "FluidStreamUI", targets: ["FluidStreamUI"]),
    ],
    // No dependencies, by design. The benchmark harness lives in the separate FluidStreamBench
    // package, so comparisons against other libraries never add dependencies here.
    targets: [
        .target(
            name: "FluidStreamCore",
            swiftSettings: strictSettings
        ),
        // Pure Swift, with no Foundation and no dependency on Core: it consumes plain `String` deltas.
        .target(
            name: "FluidStreamParser",
            swiftSettings: strictSettings
        ),
        // TextKit 2 rendering. Builds against UIKit on iOS and Catalyst, and against AppKit on
        // macOS, so the document model and layout logic can be tested on the host machine.
        .target(
            name: "FluidStreamUI",
            dependencies: ["FluidStreamCore", "FluidStreamParser"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "FluidStreamUITests",
            dependencies: ["FluidStreamUI", "FluidStreamCore", "FluidStreamParser"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "FluidStreamParserTests",
            dependencies: ["FluidStreamParser"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "FluidStreamCoreTests",
            dependencies: ["FluidStreamCore"],
            swiftSettings: strictSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
