// MARK: - CompileContractTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

@Suite(
  "Compile Contract Tests",
  .enabled(if: hostProcessTestsSupported, "requires macOS subprocess support")
)
struct CompileContractTests {

  @Test("Generic extension features expose synthesized action paths")
  func genericExtensionFeatureActionPathsCompile() {
    let replacePath = GenericExtensionNamespace<Int>.Feature.Action.replaceCasePath
    let replacePathAgain = GenericExtensionNamespace<Int>.Feature.Action.replaceCasePath
    let stringReplacePath = GenericExtensionNamespace<String>.Feature.Action.replaceCasePath
    let childPath = GenericExtensionNamespace<Int>.Feature.Action.childActionPath
    let childPathAgain = GenericExtensionNamespace<Int>.Feature.Action.childActionPath

    #expect(replacePath.extract(replacePath.embed(42)) == 42)
    #expect(childPath.extract(childPath.embed(1, 42))?.0 == 1)
    #expect(childPath.extract(childPath.embed(1, 42))?.1 == 42)
    #expect(replacePath.identity == replacePathAgain.identity)
    #expect(replacePath.identity != stringReplacePath.identity)
    #expect(childPath.identity == childPathAgain.identity)
  }

  @Test("Store.scope method values support both 5.0 migration forms")
  func storeScopeMethodValueMigrationFormsCompile() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              var count = 0
          }

          struct State: Sendable {
              var child = Child()
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: { .child($0) },
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case increment
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      typealias ChildStore = ScopedStore<
          ParentFeature,
          ParentFeature.Child,
          ParentFeature.ChildAction
      >

      typealias LocatedScopeMethod = @MainActor @Sendable (
          KeyPath<ParentFeature.State, ParentFeature.Child>,
          CasePath<ParentFeature.Action, ParentFeature.ChildAction>,
          StaticString,
          UInt,
          UInt
      ) -> ChildStore

      typealias TwoArgumentScopeMethod = @MainActor @Sendable (
          KeyPath<ParentFeature.State, ParentFeature.Child>,
          CasePath<ParentFeature.Action, ParentFeature.ChildAction>
      ) -> ChildStore

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())

          let located: LocatedScopeMethod = store.scope
          let first = located(
              \\.child,
              ParentFeature.Action.childCasePath,
              #fileID,
              #line,
              #column
          )

          let wrapped: TwoArgumentScopeMethod = { state, action in
              store.scope(state: state, action: action)
          }
          let second = wrapped(\\.child, ParentFeature.Action.childCasePath)
          let rootSelection = store.select(dependingOn: \\.child.count, id: "root-count") { $0 }
          let childSelection = first.select(dependingOn: \\.count, id: "child-count") { $0 }

          _ = first.count
          _ = second.count
          _ = rootSelection.optionalValue
          _ = childSelection.optionalValue
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))
  }

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
      import InnoFlowTesting

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

  @Test("child output must be mapped before entering a different parent output space")
  func mismatchedChildOutputFailsToCompile() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlowCore

      struct Child: Reducer {
          struct State: Sendable {}
          enum Action: Sendable { case finish }
          typealias Output = String

          func reduce(
              into state: inout State,
              action: Action
          ) -> ReducerEffect<Action, Output> {
              Self.output("finished")
          }
      }

      struct Parent: Reducer {
          struct State: Sendable { var child = Child.State() }
          enum Action: Sendable { case child(Child.Action) }
          typealias Output = Int

          static let childPath = CasePath<Action, Child.Action>(
              embed: Action.child,
              extract: {
                  guard case .child(let action) = $0 else { return nil }
                  return action
              }
          )

          func reduce(
              into state: inout State,
              action: Action
          ) -> ReducerEffect<Action, Output> {
              Scope(
                  state: \\.child,
                  action: Self.childPath,
                  reducer: Child()
              )
              .reduce(into: &state, action: action)
          }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
    #expect(result.normalizedOutput.contains("String"))
    #expect(result.normalizedOutput.contains("Int"))
  }

  @Test("output promotion cannot discard a real reducer or effect output")
  func outputPromotionCannotDiscardRealOutputs() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)
    let snippets = [
      """
      import InnoFlowCore
      let child = Reduce<Int, Int, String> { _, _ in .none }
      let _ = child.promoteOutput(to: Int.self)
      """,
      """
      import InnoFlowCore
      let effect = ReducerEffect<Int, String>.none
      let _ = effect.promoteOutput(to: Int.self)
      """,
    ]

    for source in snippets {
      let result = try typecheckSource(source, moduleDirectory: moduleDirectory)
      #expect(result.status != 0, Comment(rawValue: result.normalizedOutput))
      #expect(result.normalizedOutput.contains("String"))
      #expect(result.normalizedOutput.contains("Never"))
    }
  }

  @Test("external consumers can promote Never and match non-equatable outputs")
  func outputErgonomicsArePublicAPI() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)
    let source = """
      import InnoFlowTesting

      struct Receipt: Sendable { let value: Int }

      @MainActor
      func checkPublicAPI() async {
          let child = Reduce<Int, Int, Never> { _, _ in .none }
          let parent = child.promoteOutput(to: Receipt.self)
          let effect: ReducerEffect<Int, Receipt> =
              EffectTask<Int>.send(1).promoteOutput(to: Receipt.self)
          _ = effect
          let store = TestStore(reducer: parent, initialState: 0)
          let receipt: Receipt? = await store.receiveOutput(where: { $0.value == 1 })
          let path = CasePath<Receipt, Int>(
              embed: { Receipt(value: $0) }, extract: { $0.value }
          )
          let value: Int? = await store.receiveOutput(path)
          _ = (receipt, value)
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)
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

      let first = Reduce<Int, Int, Never> { _, _ in .none }
      let second = Reduce<Int, Int, Never> { _, _ in .none }
      let _ = _ReducerSequence(first: first, second: second)
      """,
      """
      import InnoFlowCore

      let reducer = Reduce<Int, Int, Never> { _, _ in .none }
      let _ = _OptionalReducer(reducer)
      """,
      """
      import InnoFlowCore

      let first = Reduce<Int, Int, Never> { _, _ in .none }
      let second = Reduce<Int, Int, Never> { _, _ in .none }
      let _ = _ConditionalReducer(branch: .first(first))
      """,
      """
      import InnoFlowCore

      let reducer = Reduce<Int, Int, Never> { _, _ in .none }
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
    #expect(
      !result.normalizedOutput.localizedCaseInsensitiveContains("no such module 'InnoFlow'"))
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
    // A package-root release module must not outrank the running test bundle's
    // custom Debug module merely because its path sorts first. Toolchains can
    // differ between those builds, making a lexicographic choice invalid.
    let staleReleaseModule = packageRoot.appendingPathComponent(
      ".build/arm64-apple-macosx/release/InnoFlow.swiftmodule"
    )
    try FileManager.default.createDirectory(
      at: staleReleaseModule.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: staleReleaseModule.path, contents: Data())
    let foreignModule = packageRoot.appendingPathComponent(
      ".build/release-evidence/DerivedData/Build/Products/Debug-iphonesimulator/InnoFlow.swiftmodule",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: foreignModule,
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(
      atPath: foreignModule.appendingPathComponent("arm64-apple-ios-simulator.swiftmodule").path,
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
      import InnoFlowTesting

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
      let failed = StoreInstrumentation<Int>.RunFailedEvent(
          token: token,
          cancellationID: staticID,
          sequence: 6,
          errorDescription: "failed",
          errorTypeName: "SampleError"
      )
      let metrics = StoreInstrumentationMetricsSnapshot(runStarted: 1)
      let timing = EffectTimingRecorder.Entry(
          phase: .runStarted,
          sequence: 7,
          effectID: nil,
          actionLabel: nil,
          timestampNanos: 0
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
      let _ = failed.dispatchID
      let _ = metrics.runStarted
      let _ = timing.dispatchID
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
          let selected = store.select(dependingOn: \\.count, id: "count") { $0 }
          _ = selected.optionalValue
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

  @Test(
    "Public and package InnoFlow macro features work across target boundaries with source fallback"
  )
  func exportedMacroFeaturesWorkAcrossTargetBoundaries() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let clientRoot = temporaryRoot.appendingPathComponent("PublicMacroClient", isDirectory: true)
    let featureRoot = clientRoot.appendingPathComponent(
      "Sources/PublicFeatureKit",
      isDirectory: true
    )
    let executableRoot = clientRoot.appendingPathComponent(
      "Sources/PublicMacroClient",
      isDirectory: true
    )
    let buildPath = temporaryRoot.appendingPathComponent("build", isDirectory: true)
    try FileManager.default.createDirectory(at: featureRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: executableRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }

    let escapedPackagePath = packageRoot.path
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")

    let manifest = """
      // swift-tools-version: 6.3
      import PackageDescription

      let package = Package(
          name: "PublicMacroClient",
          platforms: [
              .iOS(.v18),
              .macOS(.v15),
              .tvOS(.v18),
              .watchOS(.v11),
              .visionOS(.v2)
          ],
          products: [
              .executable(name: "PublicMacroClient", targets: ["PublicMacroClient"])
          ],
          dependencies: [
              .package(name: "InnoFlow", path: "\(escapedPackagePath)")
          ],
          targets: [
              .target(
                  name: "PublicFeatureKit",
                  dependencies: [
                      .product(name: "InnoFlow", package: "InnoFlow")
                  ]
              ),
              .executableTarget(
                  name: "PublicMacroClient",
                  dependencies: [
                      "PublicFeatureKit",
                      .product(name: "InnoFlow", package: "InnoFlow")
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

    let featureSource = """
      import InnoFlow

      @InnoFlow
      public struct PublicFeature {
          public struct State: Equatable, Sendable, DefaultInitializable {
              public var count = 0
              public init() {}
          }

          public enum Action: Equatable, Sendable {
              public typealias ManualPath = CasePath<Self, (UUID, Date)>

              case increment
              case child(ChildAction)
              case row(id: Int, action: ChildAction)
              case manual(stepID: UUID, at: Date)
              case factory(stepID: UUID, at: Date)
              @InnoFlow.InnoFlowCasePathIgnored
              case ignored(stepID: UUID, at: Date)

              public static let manualCasePath: ManualPath = .init(
                  embed: { .manual(stepID: $0.0, at: $0.1) },
                  extract: { action in
                      guard case let .manual(stepID, at) = action else { return nil }
                      return (stepID, at)
                  }
              )
              public static let factoryCasePath = makeFactoryCasePath()

              private static func makeFactoryCasePath() -> CasePath<Self, (UUID, Date)> {
                  CasePath(
                      embed: { .factory(stepID: $0.0, at: $0.1) },
                      extract: { action in
                          guard case let .factory(stepID, at) = action else { return nil }
                          return (stepID, at)
                      }
                  )
              }
          }

          public enum ChildAction: Equatable, Sendable {
              case start
          }

          public init() {}

          var body: some Reducer<State, Action, Never> {
              Reduce { state, action in
                  if case .increment = action {
                      state.count += 1
                  }
                  return .none
              }
          }
      }

      @InnoFlow
      public struct GenericFeature<Value: Equatable & Sendable> {
          public struct State: Equatable, Sendable, DefaultInitializable {
              public var value: Value?
              public init() {}
          }

          public enum Action: Equatable, Sendable {
              case replace(Value)
              case child(id: Int, action: Value)
          }

          public init() {}

          var body: some Reducer<State, Action, Never> {
              Reduce { state, action in
                  switch action {
                  case .replace(let value), .child(_, let value):
                      state.value = value
                  }
                  return .none
              }
          }
      }

      @InnoFlow
      public struct PublicOutputFeature {
          public struct State: Equatable, Sendable, DefaultInitializable {
              public init() {}
          }

          public enum Action: Equatable, Sendable {
              case emit(Int)
          }

          public enum Output: Equatable, Sendable {
              case value(Int)
              case conditionalManual(Int)
              #if MANUAL_PATH
              public static let conditionalManualCasePath = CasePath<Self, Int>(
                  embed: { .conditionalManual($0) },
                  extract: { output in
                      guard case .conditionalManual(let value) = output else { return nil }
                      return value
                  }
              )
              #endif
              @available(macOS 26.0, *)
              case modern
              #if os(macOS)
              @available(macOS 26.0, *)
              #endif
              case conditionalModern
              @available(*, unavailable)
              case retired
              @available(macOS, unavailable)
              case retiredOnMac
              @available(macOS, message: "arguments can be reordered", unavailable)
              case reorderedUnavailableOnMac
              #if os(macOS)
              @available(*, unavailable)
              #endif
              case conditionallyRetired
              #if os(macOS)
              case platform(Int)
              #elseif os(iOS)
              case platform(Double)
              #else
              case platform(String)
              #endif
              #if os(macOS)
              case independent(Int)
              #endif
              #if !os(macOS)
              case independent(String)
              #endif
              case complexManual(Int)
              #if !FEATURE_A && FEATURE_B
              public static let complexManualCasePath = CasePath<Self, Int>(
                  embed: { .complexManual($0) },
                  extract: { output in
                      guard case .complexManual(let value) = output else { return nil }
                      return value
                  }
              )
              #endif
              case complexThreeFlagManual(Int)
              #if (FEATURE_A && FEATURE_B) || FEATURE_C
              public static let complexThreeFlagManualCasePath = CasePath<Self, Int>(
                  embed: { .complexThreeFlagManual($0) },
                  extract: { output in
                      guard case .complexThreeFlagManual(let value) = output else { return nil }
                      return value
                  }
              )
              #endif
              case disjunctionManual(Int)
              #if !FEATURE_A || FEATURE_B
              public static let disjunctionManualCasePath = CasePath<Self, Int>(
                  embed: { .disjunctionManual($0) },
                  extract: { output in
                      guard case .disjunctionManual(let value) = output else { return nil }
                      return value
                  }
              )
              #endif
              case doubleNegationManual(Int)
              #if !(!FEATURE_A)
              public static let doubleNegationManualCasePath = CasePath<Self, Int>(
                  embed: { .doubleNegationManual($0) },
                  extract: { output in
                      guard case .doubleNegationManual(let value) = output else { return nil }
                      return value
                  }
              )
              #endif
              #if os(macOS)
              case parenthesizedPlatform(Int)
              #endif
              #if !(os(macOS))
              case parenthesizedPlatform(String)
              #endif
              #if arch(arm64)
              case architecture(Int)
              #elseif arch(x86_64)
              case architecture(Int)
              #endif
              #if swift(>=6.0)
              case swiftVersion(Int)
              #else
              case swiftVersion(Int)
              #endif
              #if compiler(>=6.0)
              case compilerVersion(Int)
              #else
              case compilerVersion(Int)
              #endif
              #if targetEnvironment(simulator)
              case targetSpecific(Int)
              #endif
              #if targetEnvironment(macCatalyst)
              case targetSpecific(String)
              #endif
              @available(iOS, unavailable)
              @available(macCatalyst 13.0, *)
              case catalystOverride(Int)
              @available(macOSApplicationExtension, unavailable)
              case appOnly(Int)
              @available(macOS, introduced: 15.0, message: "unavailable is documentation, not a declaration")
              case availabilityMessage(Int)
              @available(macOS, introduced: 15.0, deprecated: 99.0, renamed: "unavailableReplacement")
              case availabilityRenamed(Int)
              #if os(macOS)
              @InnoFlowCasePathIgnored
              #endif
              case conditionallyIgnored
              #if FEATURE_A
              @InnoFlowCasePathIgnored
              #endif
              case flagIgnored
              #if FEATURE_A
              @available(*, unavailable)
              #endif
              case exclusiveValue(Int)
              #if !FEATURE_A
              @available(*, unavailable)
              #endif
              case _exclusiveValue(Int)
          }

          public init() {}

          var body: some Reducer<State, Action, Output> {
              Reduce { _, action in
                  switch action {
                  case .emit(let value):
                      return Self.output(.value(value))
                  }
              }
          }
      }

      @InnoFlow(phaseManaged: true, strictPhaseTotality: true)
      package struct PackageFeature {
          package struct State: Equatable, Sendable, DefaultInitializable {
              package enum Phase: Hashable, Sendable { case idle, loaded }
              package var phase = Phase.idle
              package init() {}
          }

          package enum Action: Equatable, Sendable {
              case child(ChildAction)
              case row(id: Int, action: ChildAction)
          }

          package enum ChildAction: Equatable, Sendable {
              case start
          }

          package static var phaseMap: PhaseMap<State, Action, State.Phase> {
              PhaseMap(\\.phase) {
                  From(.idle) { On(Action.childCasePath, to: .loaded) }
                  From(.loaded) {}
              }
          }

          package init() {}

          var body: some Reducer<State, Action, Never> {
              Reduce { _, _ in .none }
          }
      }

      public enum PublicNamespace {}

      public extension PublicNamespace {
          @InnoFlow
          struct Feature {
              public struct State: Equatable, Sendable, DefaultInitializable {
                  public init() {}
              }

              public enum Action: Equatable, Sendable {
                  case child(ChildAction)
              }

              public enum ChildAction: Equatable, Sendable {
                  case start
              }

              public init() {}

              var body: some Reducer<State, Action, Never> {
                  Reduce { _, _ in .none }
              }
          }
      }

      package enum PackageNamespace {}

      package extension PackageNamespace {
          @InnoFlow(phaseManaged: true)
          struct Feature {
              package struct State: Equatable, Sendable, DefaultInitializable {
                  package enum Phase: Hashable, Sendable { case idle, loaded }
                  package var phase = Phase.idle
                  package init() {}
              }

              package enum Action: Equatable, Sendable {
                  case child(ChildAction)
              }

              package enum ChildAction: Equatable, Sendable {
                  case start
              }

              package static var phaseMap: PhaseMap<State, Action, State.Phase> {
                  PhaseMap(\\.phase) {
                      From(.idle) { On(Action.childCasePath, to: .loaded) }
                      From(.loaded) {}
                  }
              }

              package init() {}

              var body: some Reducer<State, Action, Never> {
                  Reduce { _, _ in .none }
              }
          }
      }
      """
    try featureSource.write(
      to: featureRoot.appendingPathComponent("PublicFeature.swift"),
      atomically: true,
      encoding: .utf8
    )

    let executableSource = """
      import InnoFlow
      import PublicFeatureKit

      var state = PublicFeature.State()
      let feature = PublicFeature()
      let _ = feature.reduce(into: &state, action: .increment)
      let _ = PublicFeature.Action.childCasePath
      let _ = PublicFeature.Action.rowActionPath
      let manualPayload = (UUID(), Date())
      let _ = PublicFeature.Action.manualCasePath.embed(manualPayload)
      let _ = PublicFeature.Action.factoryCasePath.embed(manualPayload)
      let _: PublicFeature.Action = .ignored(stepID: UUID(), at: Date())

      var genericState = GenericFeature<Int>.State()
      let genericFeature = GenericFeature<Int>()
      let _ = genericFeature.reduce(into: &genericState, action: .replace(42))
      let _ = GenericFeature<Int>.Action.replaceCasePath.embed(42)
      let _ = GenericFeature<Int>.Action.childActionPath.embed(1, 42)

      @MainActor
      func compileOutputCaptureContract() async {
          let outputStore = Store(reducer: PublicOutputFeature())
          let outputTask = outputStore.send(.emit(42), capturingOutputs: .unbounded)
          var outputIterator = outputTask.outputs.makeAsyncIterator()
          await outputTask.finish()
          guard await outputIterator.next() == .value(42) else {
              fatalError("dispatch-scoped output capture failed")
          }
          let platform = PublicOutputFeature.Output.platformCasePath.embed(42)
          guard platform == .platform(42) else {
              fatalError("conditional output path failed")
          }
          let conditionalManual = PublicOutputFeature.Output.conditionalManualCasePath.embed(7)
          guard conditionalManual == .conditionalManual(7) else {
              fatalError("conditional manual output path failed")
          }
          let independent = PublicOutputFeature.Output.independentCasePath.embed(9)
          guard independent == .independent(9) else {
              fatalError("independent conditional output path failed")
          }
          let complex = PublicOutputFeature.Output.complexManualCasePath.embed(10)
          guard complex == .complexManual(10) else {
              fatalError("complex conditional manual output path failed")
          }
          let complexThreeFlag = PublicOutputFeature.Output.complexThreeFlagManualCasePath.embed(13)
          guard complexThreeFlag == .complexThreeFlagManual(13) else {
              fatalError("three-flag conditional manual output path failed")
          }
          let disjunction = PublicOutputFeature.Output.disjunctionManualCasePath.embed(15)
          guard disjunction == .disjunctionManual(15) else {
              fatalError("disjunction conditional manual output path failed")
          }
          let doubleNegation = PublicOutputFeature.Output.doubleNegationManualCasePath.embed(16)
          guard doubleNegation == .doubleNegationManual(16) else {
              fatalError("double-negation conditional manual output path failed")
          }
          let parenthesized = PublicOutputFeature.Output.parenthesizedPlatformCasePath.embed(11)
          guard parenthesized == .parenthesizedPlatform(11) else {
              fatalError("parenthesized platform output path failed")
          }
          let architecture = PublicOutputFeature.Output.architectureCasePath.embed(18)
          guard architecture == .architecture(18) else {
              fatalError("architecture conditional output path failed")
          }
          let swiftVersion = PublicOutputFeature.Output.swiftVersionCasePath.embed(19)
          guard swiftVersion == .swiftVersion(19) else {
              fatalError("Swift version conditional output path failed")
          }
          let compilerVersion = PublicOutputFeature.Output.compilerVersionCasePath.embed(21)
          guard compilerVersion == .compilerVersion(21) else {
              fatalError("compiler version conditional output path failed")
          }
          let appOnly = PublicOutputFeature.Output.appOnlyCasePath.embed(20)
          guard appOnly == .appOnly(20) else {
              fatalError("application-only output path failed")
          }
          let availabilityMessage = PublicOutputFeature.Output.availabilityMessageCasePath.embed(12)
          guard availabilityMessage == .availabilityMessage(12) else {
              fatalError("availability message output path failed")
          }
          let availabilityRenamed = PublicOutputFeature.Output.availabilityRenamedCasePath.embed(14)
          guard availabilityRenamed == .availabilityRenamed(14) else {
              fatalError("availability renamed output path failed")
          }
          #if !FEATURE_A
          let flagIgnored = PublicOutputFeature.Output.flagIgnoredCasePath.embed(())
          guard flagIgnored == .flagIgnored else {
              fatalError("conditional ignored output path failed")
          }
          let exclusiveValue = PublicOutputFeature.Output.exclusiveValueCasePath.embed(17)
          guard exclusiveValue == .exclusiveValue(17) else {
              fatalError("complementary availability output path failed")
          }
          #else
          let exclusiveValue = PublicOutputFeature.Output.exclusiveValueCasePath.embed(17)
          guard exclusiveValue == ._exclusiveValue(17) else {
              fatalError("complementary availability output path failed")
          }
          #endif
          if #available(macOS 26.0, *) {
              let modern = PublicOutputFeature.Output.modernCasePath.embed(())
              guard modern == .modern else {
                  fatalError("available output path failed")
              }
              let conditionalModern = PublicOutputFeature.Output.conditionalModernCasePath.embed(())
              guard conditionalModern == .conditionalModern else {
                  fatalError("conditional availability output path failed")
              }
          }
      }
      await compileOutputCaptureContract()

      var packageState = PackageFeature.State()
      let packageFeature = PackageFeature()
      let _ = packageFeature.reduce(into: &packageState, action: .child(.start))
      let _ = PackageFeature.Action.childCasePath
      let _ = PackageFeature.Action.rowActionPath

      var nestedPublicState = PublicNamespace.Feature.State()
      let nestedPublicFeature = PublicNamespace.Feature()
      let _ = nestedPublicFeature.reduce(into: &nestedPublicState, action: .child(.start))
      let _ = PublicNamespace.Feature.Action.childCasePath

      var nestedPackageState = PackageNamespace.Feature.State()
      let nestedPackageFeature = PackageNamespace.Feature()
      let _ = nestedPackageFeature.reduce(into: &nestedPackageState, action: .child(.start))
      let _ = PackageNamespace.Feature.Action.childCasePath

      @MainActor
      func verifySelectionIdentityAndLifetime() {
          var store: Store<PublicFeature>? = Store(reducer: PublicFeature())
          func selected(_ offset: Int) -> SelectedStore<Int> {
              store!.select(dependingOn: \\.count) { $0 + offset }
          }
          let first = selected(0)
          let second = selected(10)
          guard first !== second, first.requireAlive() == 0, second.requireAlive() == 10 else {
              fatalError("closure selections aliased different captured inputs")
          }
          func selectedStable() -> SelectedStore<Int> {
              store!.select(dependingOn: \\.count, id: "plus-five") { $0 + 5 }
          }
          let stable = selectedStable()
          let sameStable = selectedStable()
          guard stable === sameStable else {
              fatalError("explicit semantic selection identity was not reused")
          }
          store!.send(.increment)
          guard first.requireAlive() == 1, second.requireAlive() == 11,
                stable.requireAlive() == 6 else {
              fatalError("live selections did not update independently")
          }
          store = nil
          guard first.optionalValue == nil, second.optionalValue == nil,
                stable.optionalValue == nil else {
              fatalError("released parent left a selection alive")
          }
      }
      await MainActor.run { verifySelectionIdentityAndLifetime() }
      """
    try executableSource.write(
      to: executableRoot.appendingPathComponent("main.swift"),
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
        "PublicMacroClient",
        "--disable-experimental-prebuilts",
        "-Xswiftc",
        "-warnings-as-errors",
      ]
    )

    #expect(result.status == 0, Comment(rawValue: result.normalizedOutput))

    let runtimeResult = try runProcess(
      executableURL: buildPath.appendingPathComponent("debug/PublicMacroClient"),
      arguments: []
    )
    #expect(runtimeResult.status == 0, Comment(rawValue: runtimeResult.normalizedOutput))

    let manualResult = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [
        "swift",
        "build",
        "--package-path",
        clientRoot.path,
        "--build-path",
        buildPath.appendingPathComponent("manual-path").path,
        "--product",
        "PublicMacroClient",
        "--disable-experimental-prebuilts",
        "-Xswiftc",
        "-warnings-as-errors",
        "-Xswiftc",
        "-DMANUAL_PATH",
      ]
    )

    #expect(manualResult.status == 0, Comment(rawValue: manualResult.normalizedOutput))

    for flags in [
      ["FEATURE_A"],
      ["FEATURE_B"],
      ["FEATURE_C"],
      ["FEATURE_A", "FEATURE_B"],
      ["FEATURE_A", "FEATURE_C"],
      ["FEATURE_B", "FEATURE_C"],
      ["FEATURE_A", "FEATURE_B", "FEATURE_C"],
    ] {
      let flagArguments = flags.flatMap { ["-Xswiftc", "-D\($0)"] }
      let conditionalResult = try runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
        arguments: [
          "swift",
          "build",
          "--package-path",
          clientRoot.path,
          "--build-path",
          buildPath.appendingPathComponent(flags.joined(separator: "-")).path,
          "--product",
          "PublicMacroClient",
          "--disable-experimental-prebuilts",
          "-Xswiftc",
          "-warnings-as-errors",
        ] + flagArguments
      )
      #expect(
        conditionalResult.status == 0,
        Comment(rawValue: conditionalResult.normalizedOutput)
      )
    }

    let unavailableUseSource =
      executableSource + """

        let _ = PublicOutputFeature.Output.retired
        """
    try unavailableUseSource.write(
      to: executableRoot.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )
    let unavailableUseResult = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [
        "swift",
        "build",
        "--package-path",
        clientRoot.path,
        "--build-path",
        buildPath.path,
        "--product",
        "PublicMacroClient",
        "--disable-experimental-prebuilts",
        "-Xswiftc",
        "-warnings-as-errors",
      ]
    )

    #expect(unavailableUseResult.status != 0)
    #expect(
      unavailableUseResult.normalizedOutput.localizedCaseInsensitiveContains("unavailable"),
      Comment(rawValue: unavailableUseResult.normalizedOutput)
    )

    try executableSource.write(
      to: executableRoot.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )
    let applicationExtensionResult = try runProcess(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [
        "swift",
        "build",
        "--package-path",
        clientRoot.path,
        "--build-path",
        buildPath.appendingPathComponent("application-extension").path,
        "--product",
        "PublicMacroClient",
        "--disable-experimental-prebuilts",
        "-Xswiftc",
        "-warnings-as-errors",
        "-Xswiftc",
        "-application-extension",
      ]
    )
    #expect(applicationExtensionResult.status != 0)
    #expect(
      applicationExtensionResult.normalizedOutput.localizedCaseInsensitiveContains("unavailable"),
      Comment(rawValue: applicationExtensionResult.normalizedOutput)
    )
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

          var body: some Reducer<State, Action, Never> {
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

          var body: some Reducer<State, Action, Never> {
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
      // swift-tools-version: 6.3
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
              .package(name: "InnoFlow", path: "\(escapedPackagePath)")
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

      struct ExactFeature: Reducer {
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

      struct LoadFeature: Reducer {
          struct ChildState: Equatable, Sendable {
              var values: [Int] = []
          }

          struct State: Equatable, Sendable, DefaultInitializable {
              var values: [Int] = []
              var child = ChildState()
              init() {}
          }

          enum ChildAction: Sendable {
              case loaded(Int)

              static let loadedCasePath = CasePath<Self, Int>(
                  embed: Self.loaded,
                  extract: { action in
                      guard case .loaded(let value) = action else { return nil }
                      return value
                  }
              )
          }

          enum Action: Sendable {
              case loaded(Int)
              case optional(Int?)
              case child(ChildAction)

              static let loadedCasePath = CasePath<Self, Int>(
                  embed: Self.loaded,
                  extract: { action in
                      guard case .loaded(let value) = action else { return nil }
                      return value
                  }
              )

              static let optionalCasePath = CasePath<Self, Int?>(
                  embed: Self.optional,
                  extract: { action in
                      guard case .optional(let value) = action else { return nil }
                      return .some(value)
                  }
              )

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Self.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              switch action {
              case .loaded(let value):
                  state.values.append(value)
              case .optional:
                  break
              case .child(.loaded(let value)):
                  state.child.values.append(value)
              }
              return .none
          }
      }

      func requireSendable<T: Sendable>(_ value: T) {}

      @MainActor
      func compileContract() async {
          let exactStore = TestStore(reducer: ExactFeature())
          requireSendable(Exhaustivity.on)
          let _: Bool = Exhaustivity.on == .off
          let _: Exhaustivity = .off(showSkippedAssertions: true)
          exactStore.exhaustivity = .off
          _ = exactStore.exhaustivity
          await exactStore.receive(.load) { $0.didLoad = true }
          await exactStore.receive(.load, timeout: .milliseconds(10)) {
              $0.didLoad = true
          }

          let store = TestStore(reducer: LoadFeature())
          _ = store.state
          _ = await store.receive(
              LoadFeature.Action.loadedCasePath,
              caseName: "loaded",
              timeout: .milliseconds(10)
          ) { state, value in
              state.values.append(value)
          }
          let optional: Int?? = await store.receive(
              LoadFeature.Action.optionalCasePath,
              timeout: .milliseconds(10)
          )
          _ = optional
          _ = await store.receive(
              where: {
                  guard case .loaded(let value) = $0 else { return false }
                  return value > 0
              },
              description: "positive loaded value",
              timeout: .milliseconds(10)
          ) { state, action in
              guard case .loaded(let value) = action else { return }
              state.values.append(value)
          }
          await store.assertNoBufferedActions()

          let child = store.scope(
              state: \\LoadFeature.State.child,
              action: LoadFeature.Action.childCasePath
          )
          child.exhaustivity = .off(showSkippedAssertions: true)
          _ = child.exhaustivity
          _ = await child.receive(
              LoadFeature.ChildAction.loadedCasePath,
              timeout: .milliseconds(10)
          ) { state, value in
              state.values.append(value)
          }
          _ = await child.receive(
              where: {
                  guard case .loaded(let value) = $0 else { return false }
                  return value > 0
              },
              timeout: .milliseconds(10)
          ) { state, action in
              guard case .loaded(let value) = action else { return }
              state.values.append(value)
          }
          await child.assertNoBufferedActions()
          await store.finish(timeout: .milliseconds(10))
          await child.finish(timeout: .milliseconds(10))
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
      // swift-tools-version: 6.3
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
              .package(name: "InnoFlow", path: "\(escapedPackagePath)")
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

          var body: some Reducer<State, Action, Never> {
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
      // swift-tools-version: 6.3
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
              .package(name: "InnoFlow", path: "\(escapedPackagePath)")
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
      let reducer = Reduce<Int, Int, Never> { state, action in
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

          var body: some Reducer<State, Action, Never> {
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
