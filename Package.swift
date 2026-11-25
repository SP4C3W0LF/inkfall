// swift-tools-version: 6.0

import Foundation
import PackageDescription

// The public repository carries the app and its build files only; the unit tests live in the
// private development repository. Declare the test target only when its sources are present,
// so a clone of the public repository builds with `swift build`.
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/InkfallTests")

let package = Package(
    name: "Inkfall",
    platforms: [
        // Runs on macOS 26 (Tahoe) and later; building still needs the macOS 27 SDK
        // for the availability-gated installAudioTap path in AudioCaptureService.
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Inkfall", targets: ["Inkfall"])
    ],
    dependencies: [
        // Pinned: a release must build exactly what was tested. Bump on purpose, with Package.resolved.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1")
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

if hasTests {
    package.targets.append(
        // Unit tests run with `swift test`. They link the app's code and never
        // launch the app, so they need no microphone or Accessibility grant.
        .testTarget(
            name: "InkfallTests",
            dependencies: ["Inkfall"],
            path: "Tests/InkfallTests",
            swiftSettings: [
                .unsafeFlags(["-disable-dynamic-actor-isolation"])
            ]
        )
    )
}
