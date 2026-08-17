// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VizioControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VizioControl", targets: ["VizioControl"]),
        .executable(name: "ButtonPressLatencyBenchmark", targets: ["ButtonPressLatencyBenchmark"]),
    ],
    targets: [
        .target(
            name: "VizioControl",
            path: "ios/VizioControl",
            exclude: [
                "Views",
                "Assets.xcassets",
                "VizioControlApp.swift",
                "Info.plist",
                "VizioControl.entitlements",
            ]
        ),
        .executableTarget(
            name: "ButtonPressLatencyBenchmark",
            dependencies: ["VizioControl"],
            path: "benchmarks"
        ),
        .testTarget(
            name: "VizioControlTests",
            dependencies: ["VizioControl"],
            path: "ios/VizioControlTests"
        ),
    ]
)
