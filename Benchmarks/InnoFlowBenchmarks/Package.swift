// swift-tools-version: 6.3
import Foundation
import PackageDescription
let package = Package(
  name: "InnoFlowBenchmarks",
  platforms: [.macOS(.v15), .iOS(.v18)],
  dependencies: [.package(name: "InnoFlow", path: ProcessInfo.processInfo.environment["INNOFLOW_BENCHMARK_PACKAGE"] ?? "../..")],
  targets: [.executableTarget(name: "InnoFlowBenchmarks", dependencies: [
    .product(name: "InnoFlowCore", package: "InnoFlow"),
    .product(name: "InnoFlowTesting", package: "InnoFlow"),
    .product(name: "InnoFlowSwiftUI", package: "InnoFlow", condition: .when(platforms: [.macOS, .iOS]))
  ])]
)
