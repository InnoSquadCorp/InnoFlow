// swift-tools-version: 6.3
import Foundation
import PackageDescription

let package = Package(
  name: "LevelOneConsumer", platforms: [.macOS(.v15)],
  dependencies: [
    .package(
      name: "InnoFlow",
      path: ProcessInfo.processInfo.environment["INNOFLOW_PACKAGE_PATH"] ?? "../../..")
  ],
  targets: [
    .executableTarget(
      name: "LevelOneConsumer",
      dependencies: [
        .product(name: "InnoFlow", package: "InnoFlow"),
        .product(name: "InnoFlowTesting", package: "InnoFlow"),
      ], swiftSettings: [.swiftLanguageMode(.v6)])
  ])
