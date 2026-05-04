// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "InnoFlow",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "InnoFlow",
            targets: ["InnoFlow"]
        ),
        .library(
            name: "InnoFlowTesting",
            targets: ["InnoFlowTesting"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.1"),
    ],
    targets: [
        // MARK: - Core Library
        .target(
            name: "InnoFlow",
            dependencies: ["InnoFlowMacros"]
        ),

        // MARK: - Macro Implementation
        .macro(
            name: "InnoFlowMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ]
        ),
        
        // MARK: - Testing Utilities
        .target(
            name: "InnoFlowTesting",
            dependencies: ["InnoFlow"]
        ),
        
        // MARK: - Tests
        .testTarget(
            name: "InnoFlowTests",
            dependencies: [
                "InnoFlow",
                "InnoFlowTesting",
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "InnoFlowMacrosTests",
            dependencies: [
                "InnoFlowMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
