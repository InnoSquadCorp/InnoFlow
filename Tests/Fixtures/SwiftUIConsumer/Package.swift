// swift-tools-version: 6.3
import Foundation
import PackageDescription

let package = Package(
  name: "SwiftUIConsumer",
  platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
  dependencies: [
    .package(
      name: "InnoFlow",
      path: ProcessInfo.processInfo.environment["INNOFLOW_PACKAGE_PATH"] ?? "../../..")
  ],
  targets: [
    .target(
      name: "SwiftUIConsumer",
      dependencies: [
        .product(name: "InnoFlowCore", package: "InnoFlow"),
        .product(name: "InnoFlowSwiftUI", package: "InnoFlow"),
        .product(name: "InnoFlowInspector", package: "InnoFlow"),
      ])
  ]
)
