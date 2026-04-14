// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenScribe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenScribe",
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
