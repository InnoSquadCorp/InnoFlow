// swift-tools-version: 6.3
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["INNOFLOW_CONSUMER_PACKAGE_PATH"] ?? "../../.."
let negative = ProcessInfo.processInfo.environment["INNOFLOW_COLLECTION_CONSUMER_NEGATIVE"] ?? "0"
let previousInitializer = negative == "1"
let keyPathNegative = negative != "0" && !previousInitializer
let negativeParts = negative.split(separator: "-").map(String.init)
let negativeSettings: [SwiftSetting] =
  keyPathNegative
  ? [
    .define("NEGATIVE_" + negativeParts[0].uppercased()),
    .define("NEGATIVE_" + negativeParts[1].uppercased()),
  ] : []
let excludes =
  previousInitializer
  ? ["README.md", "Sources", "Shared", "Negative/NonSendableKeyPath.swift"]
  : keyPathNegative
    ? ["README.md", "Sources", "Negative/PreviousInitializer.swift"]
    : ["README.md", "Negative"]
let sourcePaths =
  previousInitializer
  ? ["Negative/PreviousInitializer.swift"]
  : keyPathNegative ? ["Shared", "Negative/NonSendableKeyPath.swift"] : ["Sources", "Shared"]
let package = Package(
  name: "CollectionLifetimeConsumer",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "InnoFlow", path: root)],
  targets: [
    .executableTarget(
      name: "Consumer",
      dependencies: [.product(name: "InnoFlowCore", package: "InnoFlow")],
      path: ".",
      exclude: excludes,
      sources: sourcePaths,
      swiftSettings: [
        .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
      ]
        + negativeSettings
    )
  ]
)
