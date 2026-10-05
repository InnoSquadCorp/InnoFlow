// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "TCAComparison", platforms: [.macOS(.v15)], dependencies: [
  .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.26.2")
], targets: [.executableTarget(name: "TCAComparison", dependencies: [
  .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
])])
