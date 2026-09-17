// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "CatalystMacroConsumer",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [.library(name: "CatalystMacroConsumer", targets: ["CatalystMacroConsumer"])],
  dependencies: [.package(path: "../../../..")],
  targets: [
    .target(
      name: "CatalystMacroConsumer",
      dependencies: [.product(name: "InnoFlow", package: "InnoFlow")]
    )
  ]
)
