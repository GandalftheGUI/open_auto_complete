// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenAutoComplete",
    platforms: [.macOS(.v14)],
    dependencies: [
        // LLM/VLM libraries were split out of mlx-swift-examples into their own repo.
        // mlx-swift-lm has current Gemma 3 / Gemma 4 loaders; the old package doesn't.
        // Pinned to main branch because the `gemma4` model type isn't registered in
        // any tagged release yet (last tag 2.31.3 from Apr 1 2026 still missing it).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        // The MLXHuggingFace macros expand into code that references
        // HuggingFace.HubClient (from swift-huggingface) and Tokenizers (from
        // swift-transformers) — both modules need to be visible to the call site.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.1"),
    ],
    targets: [
        .executableTarget(
            name: "OpenAutoComplete",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/OpenAutoComplete",
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
