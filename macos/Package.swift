// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Andcintosh",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AndcintoshCore", targets: ["AndcintoshCore"]),
        .library(name: "AndcintoshPlatform", targets: ["AndcintoshPlatform"]),
    ],
    targets: [
        .target(name: "AndcintoshCore"),
        .target(name: "AndcintoshPlatform", dependencies: ["AndcintoshCore"]),
        .testTarget(name: "AndcintoshCoreTests", dependencies: ["AndcintoshCore"]),
    ]
)
