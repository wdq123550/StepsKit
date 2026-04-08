// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StepsKit",
    // 指定支持的平台版本，从 iOS 17.0 开始
    platforms: [
        .iOS(.v17)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "StepsKit",
            targets: ["StepsKit"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "StepsKit"
        ),
        .testTarget(
            name: "StepsKitTests",
            dependencies: ["StepsKit"]
        ),
    ]
)
