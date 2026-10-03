// swift-tools-version: 6.3
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["INNOFLOW_CONSUMER_PACKAGE_PATH"] ?? "../../.."
let negative = ProcessInfo.processInfo.environment["INNOFLOW_IDENTITY_NEGATIVE"]
let selectedSources = negative.map { ["Negative/\($0).swift"] } ?? ["Sources/Consumer/Main.swift"]
let allSources = [
  "Sources/Consumer/Main.swift", "Negative/RawValue.swift", "Negative/UUIDRecord.swift",
]
let excludedSources = allSources.filter { !selectedSources.contains($0) }
let package = Package(
  name: "DispatchIdentityConsumer", platforms: [.macOS(.v15)],
  dependencies: [
    .package(name: "InnoFlow", path: root)
  ],
  targets: [
    .executableTarget(
      name: "Consumer",
      dependencies: [
        .product(name: "InnoFlowCore", package: "InnoFlow"),
        .product(name: "InnoFlowTesting", package: "InnoFlow"),
      ], path: ".", exclude: excludedSources,
      sources: selectedSources)
  ])
