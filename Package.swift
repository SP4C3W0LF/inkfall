// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Inkfall",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "Inkfall", targets: ["Inkfall"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Inkfall",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Inkfall",
            swiftSettings: [
                // macOS 26/27 beta + Swift 6.2: the compiler-inserted dynamic
                // actor-isolation assertion (`_checkExpectedExecutor`) on @objc
                // @MainActor methods crashes when AppKit invokes them via sendAction
                // (status item AND window buttons), because the executor identity
                // check dereferences a null/foreign executor. Static isolation
                // checking still applies; only the crashing runtime assertion is off.
                .unsafeFlags(["-disable-dynamic-actor-isolation"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
