// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CollaborationKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CollaborationKit", targets: ["CollaborationKit"]),
        .executable(name: "collab-cli", targets: ["collab-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "CollaborationKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "collab-cli",
            dependencies: [
                "CollaborationKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "CollaborationKitTests",
            dependencies: ["CollaborationKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
