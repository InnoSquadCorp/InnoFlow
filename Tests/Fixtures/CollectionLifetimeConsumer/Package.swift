// swift-tools-version: 6.3
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["INNOFLOW_CONSUMER_PACKAGE_PATH"] ?? "../../.."
let negative = ProcessInfo.processInfo.environment["INNOFLOW_COLLECTION_CONSUMER_NEGATIVE"] == "1"
let package = Package(
  name: "CollectionLifetimeConsumer",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "InnoFlow", path: root)],
  targets: [
    .executableTarget(
      name: "Consumer",
      dependencies: [.product(name: "InnoFlowCore", package: "InnoFlow")],
      path: ".",
      exclude: negative ? ["README.md", "Sources"] : ["README.md", "Negative"],
      sources: [negative ? "Negative/PreviousInitializer.swift" : "Sources/Consumer/Main.swift"],
      swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny")]
    )
  ]
)
