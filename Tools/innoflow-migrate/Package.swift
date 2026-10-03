// swift-tools-version: 6.3
import Foundation
import PackageDescription

// The default pin is the reviewed root resolution. CI explicitly tests the floor too.
let syntaxVersion = ProcessInfo.processInfo.environment["INNOFLOW_MIGRATE_SWIFT_SYNTAX_VERSION"] ?? "604.0.0"
precondition(["603.0.0", "604.0.0"].contains(syntaxVersion), "Supported SwiftSyntax pins: 603.0.0 or 604.0.0")

// Deliberately outside the runtime package graph.
let package = Package(
  name: "InnoFlowMigrate",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "innoflow-migrate", targets: ["InnoFlowMigrate"])],
  dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", exact: Version(stringLiteral: syntaxVersion))],
  targets: [
    .target(name: "MigrationCore", dependencies: [
      .product(name: "SwiftSyntax", package: "swift-syntax"),
      .product(name: "SwiftParser", package: "swift-syntax"),
    ]),
    .executableTarget(name: "InnoFlowMigrate", dependencies: ["MigrationCore"]),
    .testTarget(name: "MigrationCoreTests", dependencies: ["MigrationCore"]),
  ]
)
