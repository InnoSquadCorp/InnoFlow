// swift-tools-version: 6.3
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["INNOFLOW_CONSUMER_PACKAGE_PATH"] ?? "../../.."
let package = Package(
  name: "CollectionMultiScopeConsumer",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "InnoFlow", path: root)],
  targets: [
    .executableTarget(
      name: "Consumer",
      dependencies: [.product(name: "InnoFlowCore", package: "InnoFlow")],
      swiftSettings: [
        .swiftLanguageMode(.v6), .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
      ])
  ])
