// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Kio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kio", targets: ["Companion"])],
    targets: [
        .target(name: "CompanionCore"),
        .executableTarget(name: "Companion", dependencies: ["CompanionCore"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"])
    ]
)
