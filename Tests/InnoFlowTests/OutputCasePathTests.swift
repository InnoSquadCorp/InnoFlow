// MARK: - OutputCasePathTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlow
import InnoFlowTesting
import Testing

@Suite("Output case paths")
@MainActor
struct OutputCasePathTests {
  @Test("generated output paths round-trip supported payload shapes")
  func generatedPathsRoundTrip() {
    #expect(
      OutputPathFeature.Action.repeatCasePath.embed(.emit(.ready))
        == .repeat(.emit(.ready))
    )
    #expect(
      OutputPathFeature.Action.repeatCasePath.extract(.repeat(.emit(.ready)))
        == .emit(.ready)
    )
    #expect(OutputPathFeature.Output.readyCasePath.embed(()) == .ready)
    #expect(OutputPathFeature.Output.readyCasePath.extract(.ready) != nil)
    #expect(OutputPathFeature.Output.valueCasePath.embed(7) == .value(7))
    #expect(OutputPathFeature.Output.valueCasePath.extract(.value(7)) == 7)
    #expect(OutputPathFeature.Output.selectedCasePath.embed(11) == .selected(id: 11))
    #expect(OutputPathFeature.Output.selectedCasePath.extract(.selected(id: 11)) == 11)

    let failure = OutputPathFeature.Output.failureCasePath.embed(
      (code: 503, message: "unavailable")
    )
    #expect(failure == .failure(code: 503, message: "unavailable"))
    #expect(OutputPathFeature.Output.failureCasePath.extract(failure)?.code == 503)
    #expect(OutputPathFeature.Output.failureCasePath.extract(failure)?.message == "unavailable")
  }

  @Test("optional nil output remains distinct from a path mismatch")
  func optionalNilIsPreserved() {
    let extracted: Int?? = OutputPathFeature.Output.optionalCasePath.extract(.optional(nil))
    #expect(extracted != nil)
    #expect(extracted! == nil)
    #expect(OutputPathFeature.Output.optionalCasePath.extract(.ready) == nil)
    #expect(OutputPathFeature.Output.continueCasePath.embed(3) == .continue(3))
    #expect(OutputPathFeature.Output.continueCasePath.extract(.continue(3)) == 3)
  }

  @Test("platform-guarded and available output paths preserve their declarations")
  func platformGuardsArePreserved() {
    #if os(macOS)
      #expect(OutputPathFeature.Output.platformCasePath.embed(7) == .platform(7))
      #expect(OutputPathFeature.Output.platformCasePath.extract(.platform(7)) == 7)
    #else
      #expect(OutputPathFeature.Output.platformCasePath.embed("portable") == .platform("portable"))
      #expect(
        OutputPathFeature.Output.platformCasePath.extract(.platform("portable")) == "portable"
      )
    #endif

    if #available(macOS 26.0, *) {
      #expect(OutputPathFeature.Output.modernCasePath.embed(()) == .modern)
      #expect(OutputPathFeature.Output.modernCasePath.extract(.modern) != nil)
    }

    #if arch(arm64) || arch(x86_64)
      #expect(OutputPathFeature.Output.architectureCasePath.embed(9) == .architecture(9))
    #endif

    #if swift(>=6.0)
      #expect(OutputPathFeature.Output.swiftVersionCasePath.embed(10) == .swiftVersion(10))
    #endif

    #if compiler(>=6.0)
      #expect(OutputPathFeature.Output.compilerVersionCasePath.embed(12) == .compilerVersion(12))
    #endif

    #if os(macOS)
      #expect(OutputPathFeature.Output.appOnlyCasePath.embed(11) == .appOnly(11))
    #endif
  }

  @Test("scoped store receives a root output through a generated path")
  func scopedStoreReceivesRootOutput() async {
    let store = TestStore(reducer: OutputPathFeature())
    let child = store.scope(
      state: \.child,
      action: OutputPathFeature.Action.childCasePath
    )

    await child.send(.emit(.selected(id: 42)))
    let selected = await child.receiveOutput(
      OutputPathFeature.Output.selectedCasePath,
      caseName: "selected"
    )

    #expect(selected == 42)
    await child.finish()
  }

  @Test("scoped output matching does not skip an exhaustive sibling")
  func scopedStoreReportsSiblingMismatch() async {
    let store = TestStore(reducer: OutputPathFeature())
    let child = store.scope(
      state: \.child,
      action: OutputPathFeature.Action.childCasePath
    )
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }

    await child.send(.emit(.ready))
    let selected = await child.receiveOutput(
      OutputPathFeature.Output.selectedCasePath,
      caseName: "selected"
    )

    #expect(selected == nil)
    #expect(failures.count == 1)
    #expect(failures[0].contains("Received unexpected output"))
    #expect(failures[0].contains("selected"))
    #expect(failures[0].contains("ready"))
    await child.finish()
  }

  @Test("scoped output matching preserves optional nil")
  func scopedStorePreservesOptionalNil() async {
    let store = TestStore(reducer: OutputPathFeature())
    let child = store.scope(
      state: \.child,
      action: OutputPathFeature.Action.childCasePath
    )

    await child.send(.emit(.optional(nil)))
    let value: Int?? = await child.receiveOutput(
      OutputPathFeature.Output.optionalCasePath,
      caseName: "optional"
    )

    #expect(value != nil)
    #expect(value! == nil)
    await child.finish()
  }
}

@InnoFlow
private struct OutputPathFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child = ChildState()
    init() {}
  }

  struct ChildState: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    case child(ChildAction)
    case `repeat`(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case emit(Output)
  }

  enum Output: Equatable, Sendable {
    case ready
    case value(Int)
    case selected(id: Int)
    case failure(code: Int, message: String)
    case optional(Int?)
    case `continue`(Int)
    @available(macOS 26.0, *)
    case modern
    #if os(macOS)
      case platform(Int)
    #else
      case platform(String)
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
    #if os(macOS)
      @available(macOSApplicationExtension, unavailable)
      case appOnly(Int)
    #endif
  }

  var body: some Reducer<State, Action, Output> {
    Reduce { _, action in
      switch action {
      case .child(.emit(let output)), .repeat(.emit(let output)):
        return Self.output(output)
      }
    }
  }
}
