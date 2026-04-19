// swift-tools-version:6.0
import PackageDescription

// Minimal reproduction for a SIL EarlyPerfInliner crash observed on Swift 6.3
// when building InnoFlow with `swift build -c release`.
//
// Running this should reproduce:
//   swift build --package-path Repro/SILCrashRepro -c release
//
// The crash manifests as a segfault inside the SIL pass
// `isCallerAndCalleeLayoutConstraintsCompatible` while scanning a
// `@MainActor isolated deinit` on a generic class that stores
// result-builder-composed value types.
let package = Package(
  name: "SILCrashRepro",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "SILCrashRepro", targets: ["SILCrashRepro"])
  ],
  targets: [
    .target(name: "SILCrashRepro")
  ]
)
