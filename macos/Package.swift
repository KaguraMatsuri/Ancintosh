// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ancintosh",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AncintoshCore", targets: ["AncintoshCore"]),
        .library(name: "AncintoshPlatform", targets: ["AncintoshPlatform"]),
        .executable(name: "Ancintosh", targets: ["AncintoshApp"]),
    ],
    targets: [
        .target(name: "AncintoshCore"),
        .target(name: "AncintoshPlatform", dependencies: ["AncintoshCore"]),
        .executableTarget(name: "AncintoshApp", dependencies: ["AncintoshPlatform", "AncintoshCore"]),
        .testTarget(name: "AncintoshCoreTests", dependencies: ["AncintoshCore"]),
        .testTarget(name: "AncintoshPlatformTests", dependencies: ["AncintoshPlatform", "AncintoshCore"]),
    ]
)
