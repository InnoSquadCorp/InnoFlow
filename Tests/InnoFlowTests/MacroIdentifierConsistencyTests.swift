// MARK: - MacroIdentifierConsistencyTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlow
import Testing

/// These are compiler consumers, not expansion-only snapshots. Keep the raw
/// enum control beside the macro consumers to distinguish language support
/// from generated-source failures on each supported Swift toolchain.
@Suite("Macro identifier consistency")
struct MacroIdentifierConsistencyTests {
  @Test("the original enum accepts the same keyword and raw identifier spellings")
  func originalEnumControl() {
    let values: [IdentifierEnumControl] = [
      .default(1), .`raw name`(2), .`raw-name`(3), .`123`(4), .étoile(5),
      .`tuple label`(`first value`: 6, default: "seven"),
    ]
    #expect(values.count == 6)
  }

  @Test("Action names round-trip without changing logical names")
  func actionPathsRoundTrip() {
    typealias Action = IdentifierPathFeature.Action
    #expect(Action.defaultCasePath.embed(1) == .default(1))
    #expect(Action.defaultCasePath.extract(.default(2)) == 2)
    #expect(Action.`raw nameCasePath`.embed(3) == .`raw name`(3))
    #expect(Action.`raw-nameCasePath`.extract(.`raw-name`(4)) == 4)
    #expect(Action.`123CasePath`.embed(5) == .`123`(5))
    #expect(Action.étoileCasePath.extract(.étoile(6)) == 6)
    #expect(Action.loadedCasePath.embed(7) == ._loaded(7))
    #expect(Action._doubleCasePath.embed(8) == .__double(8))
    #expect(Action.`child routeActionPath`.embed(9, "ten") == .`child route`(id: 9, action: "ten"))
    #expect(Action.`child routeActionPath`.extract(.`child route`(id: 9, action: "ten"))?.0 == 9)
    #expect(Action.`manual actionCasePath`.embed(11) == .`manual action`(value: 11))
    #expect(Action.`raw nameCasePath`.extract(.default(12)) == nil)
  }

  @Test("Output names and tuple labels retain their spelling")
  func outputPathsRoundTrip() {
    typealias Output = IdentifierPathFeature.Output
    #expect(Output.defaultCasePath.embed(()) == .default)
    #expect(Output.defaultCasePath.extract(.default) != nil)
    #expect(Output.`raw nameCasePath`.embed(1) == .`raw name`(1))
    #expect(Output.`raw-nameCasePath`.extract(.`raw-name`(2)) == 2)
    #expect(Output.`123CasePath`.embed(3) == .`123`(3))
    #expect(Output.étoileCasePath.extract(.étoile(4)) == 4)
    #expect(Output.loadedCasePath.embed(5) == ._loaded(5))
    #expect(Output._doubleCasePath.embed(6) == .__double(6))
    let pair = Output.`tuple labelCasePath`.embed((`first value`: 7, default: "eight"))
    #expect(pair == .`tuple label`(`first value`: 7, default: "eight"))
    #expect(Output.`tuple labelCasePath`.extract(pair)?.`first value` == 7)
    #expect(Output.`tuple labelCasePath`.extract(pair)?.default == "eight")
    #expect(Output.`manual outputCasePath`.embed(9) == .`manual output`(9))
    #expect(Output.`raw nameCasePath`.extract(.default) == nil)
  }

  @Test("generic and extension consumers escape stable identity markers")
  func computedPathsRoundTrip() {
    typealias Generic = GenericIdentifierFeature<Int>
    #expect(Generic.Action.`raw actionCasePath`.embed(1) == .`raw action`(1))
    #expect(Generic.Output.`raw outputCasePath`.extract(.`raw output`(2)) == 2)
    #expect(Generic.Action.`child routeActionPath`.embed(3, 4) == .`child route`(id: 3, action: 4))
    typealias Nested = IdentifierContainer<Int>.Feature
    #expect(Nested.Action.`raw actionCasePath`.extract(.`raw action`(5)) == 5)
    #expect(Nested.Output.`raw outputCasePath`.embed(6) == .`raw output`(6))
  }

  @Test("conditional and available raw output paths preserve branch ownership")
  func conditionalPathsRoundTrip() {
    typealias Output = IdentifierPathFeature.Output
    #if os(macOS)
      #expect(Output.`platform valueCasePath`.embed(7) == .`platform value`(7))
    #else
      #expect(Output.`platform valueCasePath`.embed("portable") == .`platform value`("portable"))
    #endif
    if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
      #expect(Output.`available valueCasePath`.embed(()) == .`available value`)
    }
  }

  @Test("strict totality accepts escaped declarations and unescaped references")
  func phaseKeywordReferencesMatch() {
    var state = IdentifierPhaseFeature.State()
    _ = IdentifierPhaseFeature().reduce(into: &state, action: .advance)
    #expect(state.phase == .`finished phase`)
    _ = IdentifierPhaseFeature().reduce(into: &state, action: .advance)
    #expect(state.phase == .`repeat`)
    _ = IdentifierPhaseFeature().reduce(into: &state, action: .advance)
    #expect(state.phase == .default)
  }
}

private enum IdentifierEnumControl: Equatable {
  case `default`(Int)
  case `raw name`(Int)
  case `raw-name`(Int)
  case `123`(Int)
  case `étoile`(Int)
  case `tuple label`(`first value`: Int, `default`: String)
}

@InnoFlow
private struct IdentifierPathFeature {
  struct State: Equatable, Sendable {}
  enum Action: Equatable, Sendable {
    case `default`(Int)
    case `raw name`(Int)
    case `raw-name`(Int)
    case `123`(Int)
    case `étoile`(Int)
    case _loaded(Int)
    // swift-format-ignore: AlwaysUseLowerCamelCase
    case __double(Int)
    case `child route`(`id`: Int, `action`: String)
    case `manual action`(value: Int)
    @InnoFlowCasePathIgnored case `ignored action`(value: Int, other: Int)
    static let `manual actionCasePath` = CasePath<Self, Int>(
      embed: { .`manual action`(value: $0) },
      extract: { if case .`manual action`(let value) = $0 { value } else { nil } }
    )
  }
  enum Output: Equatable, Sendable {
    case `default`
    case `raw name`(Int)
    case `raw-name`(Int)
    case `123`(Int)
    case `étoile`(Int)
    case _loaded(Int)
    // swift-format-ignore: AlwaysUseLowerCamelCase
    case __double(Int)
    case `tuple label`(`first value`: Int, `default`: String)
    case `manual output`(Int)
    @InnoFlowCasePathIgnored case `ignored output`(Int)
    static let `manual outputCasePath` = CasePath<Self, Int>(
      embed: { .`manual output`($0) },
      extract: { if case .`manual output`(let value) = $0 { value } else { nil } }
    )
    #if os(macOS)
      case `platform value`(Int)
    #else
      case `platform value`(String)
    #endif
    // Swift permits potentially unavailable payload-free cases. Associated-value
    // availability uses a separate expansion fixture because that source shape
    // is rejected by the Apple compiler before macro-generated helpers are used.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
    case `available value`
    @available(*, unavailable)
    case `unavailable value`(Int)
  }
  var body: some Reducer<State, Action, Output> { Reduce { _, _ in .none } }
}

@InnoFlow
private struct GenericIdentifierFeature<Value: Equatable & Sendable> {
  struct State: Equatable, Sendable {}
  enum Action: Equatable, Sendable {
    case `raw action`(Value)
    case `child route`(id: Int, action: Value)
  }
  enum Output: Equatable, Sendable { case `raw output`(Value) }
  var body: some Reducer<State, Action, Output> { Reduce { _, _ in .none } }
}

private struct IdentifierContainer<Value: Equatable & Sendable> {}

extension IdentifierContainer {
  @InnoFlow
  struct Feature {
    struct State: Equatable, Sendable {}
    enum Action: Equatable, Sendable { case `raw action`(Value) }
    enum Output: Equatable, Sendable { case `raw output`(Value) }
    var body: some Reducer<State, Action, Output> { Reduce { _, _ in .none } }
  }
}

@InnoFlow(phaseManaged: true, strictPhaseTotality: true)
private struct IdentifierPhaseFeature {
  struct `State`: Equatable, Sendable {
    enum `Phase`: Hashable, Sendable { case `default`, `finished phase`, `repeat` }
    var phase: Phase = .default
  }
  enum `Action`: Equatable, Sendable { case advance }
  static var `phaseMap`: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      `From`(.default) { `On`(.advance, to: .`finished phase`) }
      From(.`finished phase`) { On(.advance, to: .repeat) }
      From(.`repeat`) { On(.advance, to: .`default`) }
    }
  }
  var `body`: some `Reducer`<`State`, `Action`, `Never`> { Reduce { _, _ in .none } }
}
