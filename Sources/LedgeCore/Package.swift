// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LedgeCore", targets: ["LedgeCore"]),
    ],
    targets: [
        .target(
            name: "LedgeCore",
            path: ".",
            sources: ["Geometry", "StateMachine", "Capture", "Runner", "Vault", "Support"]
        ),
        // Documented deviation from §3's layout diagram (which draws
        // Tests/LedgeCoreTests at the repo root): SPM forbids target paths
        // outside the package root, and §3's own Makefile contract
        // (`swift test --package-path Sources/LedgeCore`) requires the tests
        // in-package — so they live at Sources/LedgeCore/Tests/LedgeCoreTests.
        // Repo-root Tests/fixtures stays where §3 puts it; TestSupport.swift
        // climbs up to reach it.
        .testTarget(
            name: "LedgeCoreTests",
            dependencies: ["LedgeCore"],
            path: "Tests/LedgeCoreTests"
        ),
    ]
)
