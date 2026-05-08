// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "InnoFlowSampleAppFeature",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
    .tvOS(.v18),
    .watchOS(.v11),
    .visionOS(.v2),
  ],
  products: [
    .library(
      name: "InnoFlowSampleAppFeature",
      targets: ["InnoFlowSampleAppFeature"]
    )
  ],
  dependencies: [
    .package(name: "InnoFlow", path: "../../../")
  ],
  targets: [
    .target(
      name: "InnoFlowSampleAppFeature",
      dependencies: [
        .product(name: "InnoFlow", package: "InnoFlow"),
        .product(name: "InnoFlowSwiftUI", package: "InnoFlow"),
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
