// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "InnoFlowSkillConsumer",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "FlowSkillExample", targets: ["FlowSkillExample"])],
    dependencies: [
        .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", exact: "6.0.2")
    ],
    targets: [
        .target(name: "FlowSkillExample", dependencies: [
            .product(name: "InnoFlow", package: "InnoFlow"),
            .product(name: "InnoFlowSwiftUI", package: "InnoFlow")
        ]),
        .testTarget(name: "FlowSkillExampleTests", dependencies: [
            "FlowSkillExample",
            .product(name: "InnoFlowTesting", package: "InnoFlow")
        ])
    ]
)
