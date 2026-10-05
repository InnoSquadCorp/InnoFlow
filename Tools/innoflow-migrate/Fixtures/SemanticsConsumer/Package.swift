// swift-tools-version: 6.3
import Foundation
import PackageDescription
let packagePath = ProcessInfo.processInfo.environment["INNOFLOW_MIGRATION_PACKAGE_PATH"]!
let package = Package(
  name: "CodemodSemanticsConsumer",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "InnoFlow", path: packagePath)],
  targets: [.testTarget(name: "MigrationSemantics", dependencies: [
    .product(name: "InnoFlow", package: "InnoFlow"),
    .product(name: "InnoFlowTesting", package: "InnoFlow"),
  ])]
)
