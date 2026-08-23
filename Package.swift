// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexQuotaBar",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "CodexQuotaBar", targets: ["CodexQuotaBar"])
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaBar",
            path: "Sources/CodexQuotaBar"
        ),
        .testTarget(
            name: "CodexQuotaBarTests",
            dependencies: ["CodexQuotaBar"],
            path: "Tests/CodexQuotaBarTests"
        )
    ]
)
