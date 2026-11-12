// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OKCrashDiagnostics",
    platforms: [.macOS(.v12)],
    products: [.library(name: "OKCrashDiagnostics", targets: ["OKCrashDiagnostics"])],
    targets: [
        .binaryTarget(name: "CrashReporter", path: "Vendor/CrashReporter.xcframework"),
        .binaryTarget(name: "Sentry",
            url: "https://github.com/getsentry/sentry-cocoa/releases/download/9.30.1/Sentry.xcframework.zip",
            checksum: "bf6bc2308b9f1d11cc0d5ad5a324dbe300afa37c8391809ecb6dd3758fa728e2"),
        .target(name: "DiagnosticHandlers"),
        .target(name: "OKCrashDiagnostics", dependencies: ["CrashReporter", "Sentry", "DiagnosticHandlers"],
                resources: [.copy("Resources/PrivacyInfo.xcprivacy"), .copy("Resources/PLCrashReporter-LICENSE.txt"), .copy("Resources/Sentry-LICENSE.txt"), .copy("Resources/Sentry-PrivacyInfo.xcprivacy")],
                linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "OKCrashDiagnosticsTests", dependencies: ["OKCrashDiagnostics"]),
        .target(name: "CrashExceptionFixture", path: "Tests/CrashExceptionFixture", publicHeadersPath: "include"),
        .executableTarget(name: "CrashDiagnosticFixture", dependencies: ["OKCrashDiagnostics", "CrashExceptionFixture"],
                          path: "Tests/CrashDiagnosticFixture"),
    ],
    swiftLanguageVersions: [.v5]
)
