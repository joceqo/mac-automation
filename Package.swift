// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "MacAutomation",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "MacAutomation",
            targets: ["MacAutomation"]
        ),
    ],
    targets: [
        .target(
            name: "MacAutomation"
        ),
        .testTarget(
            name: "MacAutomationTests",
            dependencies: ["MacAutomation"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
