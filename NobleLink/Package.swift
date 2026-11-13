// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NobleLink",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NobleKit", targets: ["NobleKit"]),
        .executable(name: "noble", targets: ["noble"]),
        .executable(name: "NobleLinkApp", targets: ["NobleLinkApp"]),
    ],
    targets: [
        .target(name: "NobleKit"),
        .executableTarget(name: "noble", dependencies: ["NobleKit"]),
        .executableTarget(name: "NobleLinkApp", dependencies: ["NobleKit"]),
        // Plain executable instead of a test target: the Command Line Tools
        // toolchain on this machine cannot build swift-testing / XCTest bundles.
        .executableTarget(name: "NobleSelfTest", dependencies: ["NobleKit"]),
    ]
)
