// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Andcintosh",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AndcintoshCore", targets: ["AndcintoshCore"]),
        .library(name: "AndcintoshPlatform", targets: ["AndcintoshPlatform"]),
        .executable(name: "Andcintosh", targets: ["AndcintoshApp"]),
    ],
    targets: [
        .target(name: "AndcintoshCore"),
        .target(name: "AndcintoshPlatform", dependencies: ["AndcintoshCore"]),
        .executableTarget(name: "AndcintoshApp", dependencies: ["AndcintoshPlatform", "AndcintoshCore"]),
        .testTarget(name: "AndcintoshCoreTests", dependencies: ["AndcintoshCore"]),
        .testTarget(name: "AndcintoshPlatformTests", dependencies: ["AndcintoshPlatform", "AndcintoshCore"]),
    ]
)
