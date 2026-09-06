// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "AndroidRuntimeKit",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "AndroidRuntimeKit",
            targets: ["AndroidRuntimeKit"]
        )
    ],
    targets: [
        .target(
            name: "AndroidRuntimeKit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AndroidRuntimeKitTests",
            dependencies: ["AndroidRuntimeKit"]
        )
    ]
)
