// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KioKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KioCore", targets: ["KioCore"]),
        .library(name: "KioModel", targets: ["KioModel"]),
        .library(name: "KioTools", targets: ["KioTools"])
    ],
    targets: [
        .target(name: "KioCore"),
        .target(name: "KioModel", dependencies: ["KioCore"]),
        .target(name: "KioTools", dependencies: ["KioCore", "KioModel"], resources: [.process("Resources")]),
        .testTarget(name: "KioCoreTests", dependencies: ["KioCore", "KioModel"]),
        .testTarget(name: "KioToolsTests", dependencies: ["KioTools", "KioCore", "KioModel"])
    ]
)
