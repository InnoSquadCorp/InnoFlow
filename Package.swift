// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let swift6PackageContract: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

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
            name: "InnoFlowSwiftUI",
            targets: ["InnoFlowSwiftUI"]
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
            dependencies: ["InnoFlowMacros"],
            swiftSettings: swift6PackageContract
        ),
        .target(
            name: "InnoFlowSwiftUI",
            dependencies: ["InnoFlow"],
            swiftSettings: swift6PackageContract
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
            ],
            swiftSettings: swift6PackageContract
        ),
        
        // MARK: - Testing Utilities
        .target(
            name: "InnoFlowTesting",
            dependencies: ["InnoFlow"],
            swiftSettings: swift6PackageContract
        ),
        
        // MARK: - Tests
        .testTarget(
            name: "InnoFlowTests",
            dependencies: [
                "InnoFlow",
                "InnoFlowSwiftUI",
                "InnoFlowTesting",
            ],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: swift6PackageContract
        ),
        .testTarget(
            name: "InnoFlowMacrosTests",
            dependencies: [
                "InnoFlowMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            swiftSettings: swift6PackageContract
        ),
    ]
)
