// swift-tools-version: 6.3
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["INNOFLOW_CONSUMER_PACKAGE_PATH"] ?? "../../.."
let negative = ProcessInfo.processInfo.environment["INNOFLOW_TESTFLOWTASK_NEGATIVE"] == "1"
let package = Package(
  name: "TestFlowTaskConsumer",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "InnoFlow", path: root)],
  targets: [
    .executableTarget(
      name: "Consumer",
      dependencies: [
        .product(name: "InnoFlowCore", package: "InnoFlow"),
        .product(name: "InnoFlowTesting", package: "InnoFlow"),
      ],
      path: ".",
      exclude: negative ? ["README.md", "Sources/Consumer/Main.swift"] : ["README.md", "Negative"],
      sources: negative
        ? ["Sources/Consumer/Feature.swift", "Negative/LegacyVoidFunctionValue.swift"]
        : ["Sources/Consumer/Feature.swift", "Sources/Consumer/Main.swift"]
    )
  ]
)
