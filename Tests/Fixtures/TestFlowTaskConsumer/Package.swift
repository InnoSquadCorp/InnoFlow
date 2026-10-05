// swift-tools-version: 6.3
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["INNOFLOW_CONSUMER_PACKAGE_PATH"] ?? "../../.."
let draft = ProcessInfo.processInfo.environment["INNOFLOW_TEST_DRAFT_NEGATIVE"] ?? ""
let flowScopeNegative = ProcessInfo.processInfo.environment["INNOFLOW_FLOWSCOPE_NEGATIVE"] == "1"
let negative = ProcessInfo.processInfo.environment["INNOFLOW_TESTFLOWTASK_NEGATIVE"] == "1"
let fixtureSources = [
  "Sources/Consumer/Feature.swift", "Sources/Consumer/Main.swift",
  "Negative/LegacyVoidFunctionValue.swift", "Negative/DirectFlowScopeInit.swift",
  "Negative/DraftAPISpellings.swift",
]
let selectedSources =
  !draft.isEmpty
  ? ["Sources/Consumer/Feature.swift", "Negative/DraftAPISpellings.swift"]
  : flowScopeNegative
    ? ["Negative/DirectFlowScopeInit.swift"]
    : negative
      ? ["Sources/Consumer/Feature.swift", "Negative/LegacyVoidFunctionValue.swift"]
      : ["Sources/Consumer/Feature.swift", "Sources/Consumer/Main.swift"]
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
      exclude: ["README.md"] + fixtureSources.filter { !selectedSources.contains($0) },
      sources: selectedSources,
      swiftSettings: draft.isEmpty
        ? [] : [.define("DRAFT_" + draft.uppercased().replacingOccurrences(of: "-", with: "_"))]
    )
  ]
)
