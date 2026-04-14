// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenScribe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "2.21.2"),
    ],
    targets: [
        .executableTarget(
            name: "OpenScribe",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ],
            path: "Sources/OpenScribe",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "AXProbe",
            path: "Sources/AXProbe",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
    ]
)
