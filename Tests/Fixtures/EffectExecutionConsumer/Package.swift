// swift-tools-version: 6.3
import Foundation
import PackageDescription

let root = ProcessInfo.processInfo.environment["INNOFLOW_CONSUMER_PACKAGE_PATH"] ?? "../../.."
let negative = ProcessInfo.processInfo.environment["INNOFLOW_EFFECT_CONSUMER_NEGATIVE"] ?? ""
let variants = [
  "capacity": "Negative/NegativeCapacity.swift",
  "admission": "Negative/PreviousAdmissionSwitch.swift",
  "removed-case": "Negative/RemovedInvalidCapacity.swift",
]
precondition(negative.isEmpty || variants[negative] != nil, "Unknown negative consumer variant")
let package = Package(
  name: "EffectExecutionConsumer",
  platforms: [.macOS(.v15)],
  dependencies: [.package(name: "InnoFlow", path: root)],
  targets: [
    .executableTarget(
      name: "Consumer",
      dependencies: [.product(name: "InnoFlowCore", package: "InnoFlow")],
      path: ".",
      exclude: negative.isEmpty
        ? ["README.md", "Negative"]
        : ["README.md", "Sources"] + variants.values.filter { $0 != variants[negative] },
      sources: [variants[negative] ?? "Sources/Consumer/Main.swift"],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
      ]
    )
  ]
)
