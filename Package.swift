// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "InnoFlow",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2)
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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
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
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftBasicFormat", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "_SwiftCompilerPluginMessageHandling", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
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
