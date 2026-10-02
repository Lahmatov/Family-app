// swift-tools-version:5.10
import PackageDescription

// Platform-independent domain logic shared by the iOS app.
// Builds and tests on Linux too (see .github/workflows/core.yml).
let package = Package(
    name: "FamilyCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FamilyCore", targets: ["FamilyCore"]),
    ],
    targets: [
        .target(
            name: "FamilyCore",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "FamilyCoreTests", dependencies: ["FamilyCore"]),
    ]
)
