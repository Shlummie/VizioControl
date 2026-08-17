// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VizioControl",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VizioControl", targets: ["VizioControl"]),
        .executable(name: "ButtonPressLatencyBenchmark", targets: ["ButtonPressLatencyBenchmark"]),
        .executable(name: "BurstButtonLatencyBenchmark", targets: ["BurstButtonLatencyBenchmark"]),
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
            path: "benchmarks",
            exclude: ["BurstButtonLatencyBenchmark"],
            sources: ["ButtonPressLatencyBenchmark.swift"]
        ),
        .executableTarget(
            name: "BurstButtonLatencyBenchmark",
            dependencies: ["VizioControl"],
            path: "benchmarks/BurstButtonLatencyBenchmark"
        ),
        .testTarget(
            name: "VizioControlTests",
            dependencies: ["VizioControl"],
            path: "ios/VizioControlTests"
        ),
    ]
)
