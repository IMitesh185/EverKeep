// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EverKeepCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "EverKeepCore", targets: ["EverKeepCore"]),
    ],
    targets: [
        .target(name: "EverKeepCore"),
        .testTarget(name: "EverKeepCoreTests", dependencies: ["EverKeepCore"]),
    ]
)
