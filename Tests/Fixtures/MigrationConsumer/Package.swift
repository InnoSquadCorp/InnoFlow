// swift-tools-version: 6.3

import Foundation
import PackageDescription

guard let packagePath = ProcessInfo.processInfo.environment["INNOFLOW_MIGRATION_PACKAGE_PATH"],
  !packagePath.isEmpty
else {
  fatalError("INNOFLOW_MIGRATION_PACKAGE_PATH is required")
}
guard let variant = ProcessInfo.processInfo.environment["INNOFLOW_MIGRATION_VARIANT"],
  ["V5Consumer", "V6Consumer"].contains(variant)
else {
  fatalError("INNOFLOW_MIGRATION_VARIANT must select V5Consumer or V6Consumer")
}

let package = Package(
  name: "InnoFlowMigrationConsumer",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "InnoFlow", path: packagePath)],
  targets: [
    .executableTarget(
      name: variant,
      dependencies: [.product(name: "InnoFlow", package: "InnoFlow")]
    ),
    .testTarget(
      name: "TestingCompat",
      dependencies: [
        .product(name: "InnoFlow", package: "InnoFlow"),
        .product(name: "InnoFlowTesting", package: "InnoFlow"),
      ],
      exclude: [variant == "V5Consumer" ? "V6Semantics.swift" : "V5Semantics.swift"],
      sources: [
        "TestingCompat.swift",
        variant == "V5Consumer" ? "V5Semantics.swift" : "V6Semantics.swift",
      ]
    ),
  ]
)
