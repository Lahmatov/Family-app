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
    dependencies: [
        // Same API as CryptoKit on Apple platforms, and the only reason the vault logic can be
        // tested on Linux. Already a transitive dependency of supabase-swift.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "FamilyCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "FamilyCoreTests", dependencies: ["FamilyCore"]),
    ]
)
