// swift-tools-version: 6.1

//===----------------------------------------------------------------------===//
//
// This source file is part of the asroutes project.
//
// Copyright (c) 2026 Craig A. Munro
//
// Licensed under the Apache License, Version 2.0.
// See the LICENSE file for details.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "asroutes",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "ASRoutesClient", targets: ["ASRoutesClient"]),
        .executable(name: "asroutes", targets: ["ASRoutesExecutable"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/RouteObjects/swift-cidr.git",
            .upToNextMinor(from: "0.5.0")
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            .upToNextMajor(from: "2.100.0")
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            .upToNextMajor(from: "1.7.0")
        ),
    ],
    targets: [
        .target(
            name: "ASRoutesClient",
            dependencies: [
                .product(name: "CIDR", package: "swift-cidr"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // Keep command behavior in an importable target so Xcode can build its tests;
        // the separately named executable target below now owns only process startup.
        .target(
            name: "ASRoutesCLI",
            dependencies: [
                "ASRoutesClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "CIDR", package: "swift-cidr"),
            ],
            path: "Sources/ASRoutesCLI"
        ),
        .executableTarget(
            name: "ASRoutesExecutable",
            dependencies: ["ASRoutesCLI"],
            // Keep process startup separate so ASRoutesCLI remains an importable,
            // testable module in both SwiftPM and Xcode.
            path: "Sources/ASRoutesExecutable"
        ),
        .testTarget(
            name: "ASRoutesClientTests",
            dependencies: [
                "ASRoutesClient",
                "ASRoutesCLI",
                .product(name: "CIDR", package: "swift-cidr"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "ASRoutesCLITests",
            dependencies: [
                "ASRoutesClient",
                "ASRoutesCLI",
                .product(name: "CIDR", package: "swift-cidr"),
            ],
            path: "Tests/ASRoutesCLITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
