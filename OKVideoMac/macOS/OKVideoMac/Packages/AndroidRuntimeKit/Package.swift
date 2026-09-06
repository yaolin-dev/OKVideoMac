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
        ),
        .executable(
            name: "android-runtime-matrix",
            targets: ["AndroidRuntimeMatrix"]
        )
    ],
    targets: [
        .target(
            name: "AndroidRuntimeKit",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AndroidRuntimeMatrix",
            dependencies: ["AndroidRuntimeKit"]
        ),
        .testTarget(
            name: "AndroidRuntimeKitTests",
            dependencies: ["AndroidRuntimeKit"]
        )
    ]
)
