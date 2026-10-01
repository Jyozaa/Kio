// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KioKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KioCore", targets: ["KioCore"]),
        .library(name: "KioModel", targets: ["KioModel"]),
        .library(name: "KioInference", targets: ["KioInference"]),
        .library(name: "KioTools", targets: ["KioTools"]),
        .library(name: "KioSync", targets: ["KioSync"]),
        .library(name: "KioUI", targets: ["KioUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.3"),
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", exact: "0.14.1"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(name: "KioCore"),
        .target(name: "KioModel", dependencies: ["KioCore"]),
        .target(name: "KioInference", dependencies: [
            "KioCore", "KioModel",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers")
        ]),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "KioTools", dependencies: ["KioCore", "CZlib", .product(name: "SwiftSoup", package: "SwiftSoup"), .product(name: "CoreXLSX", package: "CoreXLSX"), .product(name: "ZIPFoundation", package: "ZIPFoundation")]),
        .target(name: "KioSync", dependencies: ["KioCore"]),
        .target(name: "KioUI", dependencies: ["KioCore"]),
        .testTarget(name: "KioCoreTests", dependencies: ["KioCore", "KioModel"]),
        .testTarget(name: "KioToolsTests", dependencies: ["KioTools", "KioCore"]),
        .testTarget(name: "KioSyncTests", dependencies: ["KioSync"], resources: [.copy("Fixtures/relay-crypto-vector.json")])
    ]
)
