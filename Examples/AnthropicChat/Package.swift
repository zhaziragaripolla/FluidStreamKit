// swift-tools-version: 6.0
import PackageDescription

// Example: stream Claude's Messages API into FluidStreamKit.
// `AnthropicStreaming` is a small, dependency-free adapter (SSE parsing plus event bridging)
// that you can copy into your app. `App/` is a runnable SwiftUI demo built on it.
let package = Package(
    name: "AnthropicChat",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnthropicStreaming", targets: ["AnthropicStreaming"]),
    ],
    dependencies: [
        .package(path: "../.."),   // FluidStreamKit
    ],
    targets: [
        .target(
            name: "AnthropicStreaming",
            dependencies: [.product(name: "FluidStreamUI", package: "FluidStreamKit")]
        ),
        .testTarget(
            name: "AnthropicStreamingTests",
            dependencies: ["AnthropicStreaming", .product(name: "FluidStreamUI", package: "FluidStreamKit")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
