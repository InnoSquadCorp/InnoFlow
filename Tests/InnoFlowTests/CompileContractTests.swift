// MARK: - CompileContractTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

@Suite("Compile Contract Tests")
struct CompileContractTests {

  @Test("EffectID accepts dynamic and non-string raw values")
  func effectIDAcceptsDynamicAndNonStringRawValues() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import Foundation
      import InnoFlowCore

      let dynamic = String("dynamic-id")
      let stringID = StaticEffectID(dynamic)
      let uuidID = EffectID(UUID())
      let _ = EffectTask<Int>.cancel(stringID)
      let _ = EffectTask<Int>.cancel(uuidID)
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

  @Test("ReducerBuilder implementation wrappers are not public API")
  func reducerBuilderImplementationWrappersAreNotPublicAPI() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let snippets = [
      """
      import InnoFlowCore

      let _ = _EmptyReducer<Int, Int>()
      """,
      """
      import InnoFlowCore

      let first = Reduce<Int, Int> { _, _ in .none }
      let second = Reduce<Int, Int> { _, _ in .none }
      let _ = _ReducerSequence(first: first, second: second)
      """,
      """
      import InnoFlowCore

      let reducer = Reduce<Int, Int> { _, _ in .none }
      let _ = _OptionalReducer(reducer)
      """,
      """
      import InnoFlowCore

      let first = Reduce<Int, Int> { _, _ in .none }
      let second = Reduce<Int, Int> { _, _ in .none }
      let _ = _ConditionalReducer(branch: .first(first))
      """,
      """
      import InnoFlowCore

      let reducer = Reduce<Int, Int> { _, _ in .none }
      let _ = _ArrayReducer([reducer])
      """,
    ]

    for source in snippets {
      let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

      #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
      #expect(
        !result.normalizedOutput.localizedCaseInsensitiveContains("no such module 'InnoFlow'")
      )
    }
  }

  @Test("EffectContext exposes async cancellation probe")
  func effectContextExposesAsyncCancellationProbe() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import Foundation
      import InnoFlowCore

      let context = EffectContext(
          now: { ContinuousClock().now },
          sleep: { _ in },
          isCancellationRequested: { false }
      )

      func probe() async throws {
          let _ = await context.isCancellationRequested()
          try await context.checkCancellation()
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

  @Test("EffectContext no longer exposes synchronous isCancelled")
  func effectContextDoesNotExposeSynchronousIsCancelled() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import Foundation
      import InnoFlowCore

      let context = EffectContext(
          now: { ContinuousClock().now },
          sleep: { _ in },
          isCancellationRequested: { false }
      )
      let _ = context.isCancelled
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
    #expect(!result.normalizedOutput.localizedCaseInsensitiveContains("no such module 'InnoFlow'"))
  }

  @Test("Module lookup supports custom SwiftPM build paths")
  func moduleLookupSupportsCustomSwiftPMBuildPaths() throws {
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let packageRoot = temporaryRoot.appendingPathComponent("Package", isDirectory: true)
    let buildRoot = temporaryRoot.appendingPathComponent("custom-build", isDirectory: true)
    let moduleDirectory = buildRoot.appendingPathComponent("debug/Modules", isDirectory: true)
    let executableDirectory =
      buildRoot
      .appendingPathComponent(
        "debug/InnoFlowPackageTests.xctest/Contents/MacOS",
        isDirectory: true
      )

    try FileManager.default.createDirectory(
      at: moduleDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: executableDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    FileManager.default.createFile(
      atPath: moduleDirectory.appendingPathComponent("InnoFlow.swiftmodule").path,
      contents: Data()
    )

    let resolved = try findBuiltModuleDirectory(
      named: "InnoFlow",
      in: packageRoot,
      additionalSearchRoots: [executableDirectory]
    )

    #expect(resolved.path == moduleDirectory.path)
  }

  @Test("StoreInstrumentation events accept typed EffectID values")
  func storeInstrumentationEventsAcceptTypedEffectIDValues() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import Foundation
      import InnoFlowCore

      let token = UUID()
      let staticID: StaticEffectID = "legacy-id"
      let dynamicID = EffectID(UUID())
      let erasedID = AnyEffectID(staticID)

      let run = StoreInstrumentation<Int>.RunEvent(
          token: token,
          cancellationID: staticID,
          sequence: 1
      )
      let emitted = StoreInstrumentation<Int>.ActionEvent(
          action: 1,
          cancellationID: dynamicID,
          sequence: 2
      )
      let dropped = StoreInstrumentation<Int>.ActionDropEvent(
          action: nil,
          reason: .cancellationBoundary,
          cancellationID: staticID,
          sequence: 3
      )
      let cancelled = StoreInstrumentation<Int>.CancellationEvent(
          id: dynamicID,
          sequence: 4
      )
      let runWithErasedID = StoreInstrumentation<Int>.RunEvent(
          token: token,
          cancellationID: erasedID,
          sequence: nil
      )
      let emittedWithoutID = StoreInstrumentation<Int>.ActionEvent(
          action: 2,
          cancellationID: nil,
          sequence: nil
      )
      let droppedWithoutID = StoreInstrumentation<Int>.ActionDropEvent(
          action: nil,
          reason: .cancellationBoundary,
          cancellationID: nil,
          sequence: nil
      )
      let cancelledWithoutID = StoreInstrumentation<Int>.CancellationEvent(
          id: nil,
          sequence: 5
      )

      let _ = run.cancellationID
      let _ = run.cancellationID?.rawValue.description
      let _ = emitted.cancellationID
      let _ = dropped.cancellationID
      let _ = cancelled.id
      let _ = runWithErasedID.cancellationID
      let _ = emittedWithoutID.cancellationID
      let _ = droppedWithoutID.cancellationID
      let _ = cancelledWithoutID.id
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

  @Test("InnoFlow core typechecks without SwiftUI bridge")
  func innoFlowCoreTypechecksWithoutSwiftUIBridge() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore

      struct CoreFeature: Reducer {
          struct State: Equatable, Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case increment
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              state.count += 1
              return .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: CoreFeature(), initialState: .init())
          store.send(.increment)
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

  @Test("InnoFlow facade reexports core runtime types")
  func innoFlowFacadeReexportsCoreRuntimeTypes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct CoreFeature: Reducer {
          struct State: Equatable, Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case increment
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              state.count += 1
              return .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: CoreFeature(), initialState: .init())
          store.send(.increment)
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

  @Test("InnoFlowCore does not expose macro declarations")
  func innoFlowCoreDoesNotExposeMacroDeclarations() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore

      @InnoFlow
      struct MacroOnlyFeature {
          struct State: Equatable, Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case increment
          }

          var body: some Reducer<State, Action> {
              Reduce { state, action in
                  state.count += 1
                  return .none
              }
          }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
    #expect(!result.normalizedOutput.localizedCaseInsensitiveContains("no such module"))
    #expect(
      result.normalizedOutput.localizedCaseInsensitiveContains("unknown attribute")
        || result.normalizedOutput.localizedCaseInsensitiveContains("cannot find")
        || result.normalizedOutput.contains("InnoFlow")
    )
  }

  @Test("SwiftUI product reexports core runtime types")
  func swiftUIProductReexportsCoreRuntimeTypes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowSwiftUI

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, send: { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

  @Test("SwiftUI product does not expose macro declarations")
  func swiftUIProductDoesNotExposeMacroDeclarations() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowSwiftUI

      @InnoFlow
      struct MacroOnlyFeature {
          struct State: Equatable, Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case increment
          }

          var body: some Reducer<State, Action> {
              Reduce { state, action in
                  state.count += 1
                  return .none
              }
          }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
    #expect(!result.normalizedOutput.localizedCaseInsensitiveContains("no such module"))
    #expect(
      result.normalizedOutput.localizedCaseInsensitiveContains("unknown attribute")
        || result.normalizedOutput.localizedCaseInsensitiveContains("cannot find")
        || result.normalizedOutput.contains("InnoFlow")
    )
  }

  @Test("Testing product reexports core runtime types")
  func testingProductReexportsCoreRuntimeTypes() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clientRoot = temporaryRoot.appendingPathComponent("TestingClient", isDirectory: true)
    let sourceRoot = clientRoot.appendingPathComponent("Sources/TestingClient", isDirectory: true)
    let buildPath = temporaryRoot.appendingPathComponent("build", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let escapedPackagePath = packageRoot.path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    let manifest = """
      // swift-tools-version: 6.2
      import PackageDescription

      let package = Package(
          name: "TestingClient",
          platforms: [
              .iOS(.v18),
              .macOS(.v15),
              .tvOS(.v18),
              .watchOS(.v11),
              .visionOS(.v2)
          ],
          products: [
              .executable(name: "TestingClient", targets: ["TestingClient"])
          ],
          dependencies: [
              .package(path: "\(escapedPackagePath)")
          ],
          targets: [
              .executableTarget(
                  name: "TestingClient",
                  dependencies: [
                      .product(name: "InnoFlowTesting", package: "InnoFlow")
                  ]
              )
          ]
      )
      """
    try manifest.write(
      to: clientRoot.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )

    let source = """
      import InnoFlowTesting

      struct LoadFeature: Reducer {
          struct State: Equatable, Sendable, DefaultInitializable {
              var didLoad = false
              init() {}
          }

          enum Action: Equatable, Sendable {
              case load
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              state.didLoad = true
              return .none
          }
      }

      @MainActor
      func compileContract() {
          let store = TestStore(reducer: LoadFeature())
          _ = store.state
      }
      """
    try source.write(
      to: sourceRoot.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )

    let result = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [
        "swift",
        "build",
        "--package-path",
        clientRoot.path,
        "--build-path",
        buildPath.path,
        "--product",
        "TestingClient",
      ]
    )

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

  @Test("Testing product does not expose macro declarations")
  func testingProductDoesNotExposeMacroDeclarations() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clientRoot = temporaryRoot.appendingPathComponent("TestingMacroClient", isDirectory: true)
    let sourceRoot = clientRoot.appendingPathComponent(
      "Sources/TestingMacroClient",
      isDirectory: true
    )
    let buildPath = temporaryRoot.appendingPathComponent("build", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let escapedPackagePath = packageRoot.path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    let manifest = """
      // swift-tools-version: 6.2
      import PackageDescription

      let package = Package(
          name: "TestingMacroClient",
          platforms: [
              .iOS(.v18),
              .macOS(.v15),
              .tvOS(.v18),
              .watchOS(.v11),
              .visionOS(.v2)
          ],
          products: [
              .executable(name: "TestingMacroClient", targets: ["TestingMacroClient"])
          ],
          dependencies: [
              .package(path: "\(escapedPackagePath)")
          ],
          targets: [
              .executableTarget(
                  name: "TestingMacroClient",
                  dependencies: [
                      .product(name: "InnoFlowTesting", package: "InnoFlow")
                  ]
              )
          ]
      )
      """
    try manifest.write(
      to: clientRoot.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )

    let source = """
      import InnoFlowTesting

      @InnoFlow
      struct MacroOnlyFeature {
          struct State: Equatable, Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case increment
          }

          var body: some Reducer<State, Action> {
              Reduce { state, action in
                  state.count += 1
                  return .none
              }
          }
      }
      """
    try source.write(
      to: sourceRoot.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )

    let result = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [
        "swift",
        "build",
        "--package-path",
        clientRoot.path,
        "--build-path",
        buildPath.path,
        "--product",
        "TestingMacroClient",
      ]
    )

    #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
    #expect(!result.normalizedOutput.localizedCaseInsensitiveContains("no such module"))
    #expect(
      result.normalizedOutput.localizedCaseInsensitiveContains("unknown attribute")
        || result.normalizedOutput.localizedCaseInsensitiveContains("cannot find")
        || result.normalizedOutput.contains("InnoFlow")
    )
  }

  @Test("InnoFlowCore product builds without compiling macro implementation targets")
  func innoFlowCoreProductBuildsWithoutCompilingMacroImplementationTargets() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clientRoot = temporaryRoot.appendingPathComponent("CoreClient", isDirectory: true)
    let sourceRoot = clientRoot.appendingPathComponent("Sources/CoreClient", isDirectory: true)
    let buildPath = temporaryRoot.appendingPathComponent("build", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let escapedPackagePath = packageRoot.path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    let manifest = """
      // swift-tools-version: 6.2
      import PackageDescription

      let package = Package(
          name: "CoreClient",
          platforms: [
              .iOS(.v18),
              .macOS(.v15),
              .tvOS(.v18),
              .watchOS(.v11),
              .visionOS(.v2)
          ],
          products: [
              .executable(name: "CoreClient", targets: ["CoreClient"])
          ],
          dependencies: [
              .package(path: "\(escapedPackagePath)")
          ],
          targets: [
              .executableTarget(
                  name: "CoreClient",
                  dependencies: [
                      .product(name: "InnoFlowCore", package: "InnoFlow")
                  ]
              )
          ]
      )
      """
    try manifest.write(
      to: clientRoot.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )

    let source = """
      import InnoFlowCore

      var count = 0
      let reducer = Reduce<Int, Int> { state, action in
          state += action
          return .none
      }
      _ = reducer.reduce(into: &count, action: 1)
      """
    try source.write(
      to: sourceRoot.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )

    let result = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [
        "swift",
        "build",
        "--package-path",
        clientRoot.path,
        "--build-path",
        buildPath.path,
        "--product",
        "CoreClient",
        "-v",
      ]
    )

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
    // SwiftPM still resolves package-level dependencies from this single
    // manifest. This contract guards the build graph: a core-only client must
    // not compile macro implementation or SwiftSyntax product targets.
    let output = result.normalizedOutput
    let forbiddenCompileMarkers = [
      "InnoFlowMacros.build",
      "Compiling InnoFlowMacros",
      "SwiftSyntax.build",
      "SwiftSyntaxMacros.build",
      "SwiftCompilerPlugin.build",
    ]
    for marker in forbiddenCompileMarkers {
      #expect(!output.contains(marker), "Unexpected macro dependency compile marker: \(marker)")
    }
  }

  @Test("Store.binding is isolated to InnoFlowSwiftUI")
  func storeBindingRequiresInnoFlowSwiftUIImport() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, send: { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
    #expect(!result.normalizedOutput.localizedCaseInsensitiveContains("no such module"))
    #expect(
      result.normalizedOutput.localizedCaseInsensitiveContains("binding")
        || result.normalizedOutput.localizedCaseInsensitiveContains("no exact matches")
        || result.normalizedOutput.localizedCaseInsensitiveContains("has no member")
    )
  }

  @Test("Store.binding rejects non-bindable key paths at compile time")
  func bindingRejectsNonBindableKeyPathAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore
      import InnoFlowSwiftUI

      struct NonBindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case setCount(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: NonBindableFeature(), initialState: .init())
          _ = store.binding(\\.count, send: { .setCount($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("error")
        || diagnostics.localizedCaseInsensitiveContains("failed")
    )
    #expect(!diagnostics.localizedCaseInsensitiveContains("no such module"))
    #expect(
      diagnostics.localizedCaseInsensitiveContains("binding")
        || diagnostics.contains("BindableProperty")
        || diagnostics.contains("KeyPath")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.contains("CompileContract.swift")
        || diagnostics.contains("store.binding")
        || diagnostics.contains("\\.count")
        || diagnostics.contains("NonBindableFeature")
        || diagnostics.localizedCaseInsensitiveContains("generic parameter")
    )
  }

  @Test("ScopedStore.binding rejects non-bindable child key paths at compile time")
  func scopedBindingRejectsNonBindableKeyPathAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore
      import InnoFlowSwiftUI

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              var count = 0
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setCount(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.count, send: { .setCount($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("binding")
        || diagnostics.contains("BindableProperty")
        || diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.contains("\\.count")
        || diagnostics.contains("scoped")
    )
  }

  @Test("Store.binding accepts projected key paths from @BindableField authoring")
  func bindingAcceptsBindableFieldProjectedKeyPath() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore
      import InnoFlowSwiftUI

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, send: { .setStep($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(
      result.status == 0,
      "expected @BindableField projected key path to typecheck, got: \(result.normalizedOutput)")
  }

  @Test("Store.binding keeps unlabeled trailing-closure source compatibility")
  func bindingAcceptsUnlabeledTrailingClosureAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore
      import InnoFlowSwiftUI

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step) { .setStep($0) }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected unlabeled trailing-closure binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("Store.binding keeps parenthesized unlabeled source compatibility")
  func bindingAcceptsParenthesizedUnlabeledCallAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore
      import InnoFlowSwiftUI

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected parenthesized unlabeled binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("ScopedStore.binding keeps unlabeled trailing-closure source compatibility")
  func scopedBindingAcceptsUnlabeledTrailingClosureAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore
      import InnoFlowSwiftUI

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              @BindableField var step = 1
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.$step) { .setStep($0) }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected scoped unlabeled trailing-closure binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("ScopedStore.binding keeps parenthesized unlabeled source compatibility")
  func scopedBindingAcceptsParenthesizedUnlabeledCallAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore
      import InnoFlowSwiftUI

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              @BindableField var step = 1
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.$step, { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(
      result.status == 0,
      "expected scoped parenthesized unlabeled binding call to typecheck, got: \(result.normalizedOutput)"
    )
  }

  @Test("Scope/IfLet/IfCaseLet reject public closure-based action lifting at compile time")
  func reducerCompositionRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore

      struct ChildReducer: Reducer {
          struct State: Equatable, Sendable {}
          enum Action: Sendable { case start }
          func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
      }

      struct ParentReducer: Reducer {
          enum Screen: Equatable, Sendable {
              case child(ChildReducer.State)
              case idle
          }

          struct State: Equatable, Sendable {
              var child = ChildReducer.State()
              var optionalChild: ChildReducer.State? = .init()
              var screen: Screen = .child(.init())
          }

          enum Action: Sendable {
              case child(ChildReducer.Action)
          }

          static let childState = CasePath<State.Screen, ChildReducer.State>(
              embed: State.Screen.child,
              extract: { screen in
                  guard case .child(let state) = screen else { return nil }
                  return state
              }
          )

          var body: some Reducer<State, Action> {
              CombineReducers {
                  Scope(
                      state: \\.child,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )

                  IfLet(
                      state: \\.optionalChild,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )

                  IfCaseLet(
                      state: Self.childState,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )
              }
          }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("extra arguments")
        || diagnostics.localizedCaseInsensitiveContains("incorrect argument labels")
        || diagnostics.contains("extractAction")
        || diagnostics.contains("embedAction")
    )
  }

  @Test("Store.scope rejects public closure-based action lifting at compile time")
  func storeScopeRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore

      struct Todo: Equatable, Identifiable, Sendable {
          let id: UUID
          var title: String
      }

      struct ParentReducer: Reducer {
          struct Child: Equatable, Sendable {}

          struct State: Equatable, Sendable, DefaultInitializable {
              var child = Child()
              var todos = [Todo(id: UUID(), title: "One")]
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)
              case todo(id: UUID, action: TodoAction)
          }

          enum ChildAction: Sendable { case start }
          enum TodoAction: Sendable { case rename(String) }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentReducer(), initialState: .init())
          _ = store.scope(state: \\.child, action: { ParentReducer.Action.child($0) })
          _ = store.scope(collection: \\.todos, action: { id, action in ParentReducer.Action.todo(id: id, action: action) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.contains("scope")
        || diagnostics.contains("action:")
    )
  }

  @Test("TestStore.scope keeps only CasePath-based public scoping APIs")
  func testStoreScopeRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = packageRoot.appendingPathComponent("Sources/InnoFlowTesting/TestStore.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let forbiddenSignatures = [
      """
      public func scope<ChildState: Equatable, ChildAction>(
        state: WritableKeyPath<R.State, ChildState>,
        extractAction:
      """,
      """
      public func scope<CollectionState, ChildAction>(
        collection: WritableKeyPath<R.State, CollectionState>,
        id: CollectionState.Element.ID,
        extractAction:
      """,
    ]

    for signature in forbiddenSignatures {
      #expect(source.contains(signature) == false)
    }
  }

}

// MARK: - Store Tests
