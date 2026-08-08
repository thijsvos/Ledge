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
        .testTarget(
            name: "LedgeCoreTests",
            dependencies: ["LedgeCore"],
            path: "Tests/LedgeCoreTests"
        ),
    ]
)
