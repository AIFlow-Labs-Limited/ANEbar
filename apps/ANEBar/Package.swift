// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ANEBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ANEBar", targets: ["ANEBar"]),
    ],
    targets: [
        .executableTarget(
            name: "ANEBar",
            path: "Sources/ANEBar",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
    ]
)
