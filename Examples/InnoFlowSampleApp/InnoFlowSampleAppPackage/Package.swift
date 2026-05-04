// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "InnoFlowSampleAppFeature",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
    .tvOS(.v17),
    .watchOS(.v10),
    .visionOS(.v1),
  ],
  products: [
    .library(
      name: "InnoFlowSampleAppFeature",
      targets: ["InnoFlowSampleAppFeature"]
    )
  ],
  dependencies: [
    .package(name: "InnoFlow", path: "../../../"),
  ],
  targets: [
    .target(
      name: "InnoFlowSampleAppFeature",
      dependencies: [
        .product(name: "InnoFlow", package: "InnoFlow"),
      ]
    ),
    .testTarget(
      name: "InnoFlowSampleAppFeatureTests",
      dependencies: [
        "InnoFlowSampleAppFeature",
        .product(name: "InnoFlowTesting", package: "InnoFlow"),
      ]
    ),
  ]
)
