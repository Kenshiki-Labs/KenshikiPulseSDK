// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KenshikiPulseSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "KenshikiPulseSDK",
            targets: ["KenshikiPulseSDK"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "KenshikiPulseSDK",
            dependencies: []
        ),
        .testTarget(
            name: "KenshikiPulseSDKTests",
            dependencies: ["KenshikiPulseSDK"],
            resources: [
                .process("Fixtures")
            ]
        ),
    ]
)
