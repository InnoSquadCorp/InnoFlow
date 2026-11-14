// MARK: - MacroDeclarationSiteConsumerTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlow
import Testing

// These features are compiled by the real compiler, not the macro test
// harness. Each declaration below failed to compile before `Action` path
// synthesis followed the declaration site (conditional compilation,
// availability, local payload names, manual paths), before the extension
// macro honored an already-stated conformance, and before phase-map
// detection was limited to the feature's own domain. That they compile is
// the evidence; the tests then exercise what was generated.

@InnoFlow
struct DeclarationSiteChild {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case done
    }

    var phase: Phase = .idle
    var instanceID = 0
  }

  enum Action: Equatable, Sendable {
    case finish
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\.phase) {
      From(.idle) {
        On(.finish, to: .done)
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { _, _ in .none }
  }
}

/// States `Reducer` conformance in its own inheritance clause.
@InnoFlow
struct StatedConformanceFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
  }

  enum Action: Equatable, Sendable {
    case increment
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += 1
        return .none
      }
    }
  }
}

@InnoFlow
struct DeclarationSiteFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child = DeclarationSiteChild.State()
  }

  enum Action: Sendable {
    case plain(DeclarationSiteChild.Action)
    #if canImport(Swift)
      case conditional(DeclarationSiteChild.Action)
    #else
      case unreachable(DeclarationSiteChild.Action)
    #endif
    case named(_ action: DeclarationSiteChild.Action)
    @available(*, deprecated, message: "Use plain")
    case legacy(DeclarationSiteChild.Action)
    @available(*, unavailable)
    case removed(DeclarationSiteChild.Action)
    // The comment stands before a leading comma on purpose: dropping
    // `renamed:` from the copied attribute must not let the comment swallow
    // the closing parenthesis.
    // swift-format-ignore
    @available(*, deprecated  // superseded
      , renamed: "plain")
    case previous(DeclarationSiteChild.Action)
    @available(*, renamed: "plain")
    case renamedOnly(DeclarationSiteChild.Action)
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { _, _ in .none }
  }
}

/// Declares by hand the paths that 6.0.x could not synthesize. Each manual
/// path stands next to a case the macro now synthesizes and must replace that
/// synthesis instead of redeclaring it.
@InnoFlow
struct ManualPathPrecedenceFeature {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Sendable {
    case named(_ action: DeclarationSiteChild.Action)
    case row(id: Int, action: DeclarationSiteChild.Action)
    case child(DeclarationSiteChild.Action)
    #if canImport(Swift)
      case conditional(DeclarationSiteChild.Action)
      static let conditionalCasePath = CasePath<Self, DeclarationSiteChild.Action>(
        embed: { .conditional($0) },
        extract: { if case .conditional(let action) = $0 { action } else { nil } }
      )
    #endif

    static let namedCasePath = CasePath<Self, DeclarationSiteChild.Action>(
      embed: { .named($0) },
      extract: { if case .named(let action) = $0 { action } else { nil } }
    )
    static let rowActionPath = CollectionActionPath<Self, Int, DeclarationSiteChild.Action>(
      embed: { .row(id: $0, action: $1) },
      extract: { if case .row(let id, let action) = $0 { (id, action) } else { nil } }
    )
    // Inactive, so the macro synthesizes `childCasePath` under the complement.
    #if INNOFLOW_UNDEFINED_LEGACY_PATHS
      static let childCasePath = CasePath<Self, DeclarationSiteChild.Action>(
        embed: { .child($0) },
        extract: { if case .child(let action) = $0 { action } else { nil } }
      )
    #endif
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { _, _ in .none }
  }
}

/// Repeats one case name under conditions the macro cannot prove exclusive.
/// The compiler rejects the enum if both are ever active, so each helper
/// belongs inside its own clause and the two never collide.
@InnoFlow
struct RepeatedCaseNameFeature {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Sendable {
    #if canImport(Swift)
      case twin(DeclarationSiteChild.Action)
    #endif
    #if INNOFLOW_UNDEFINED_TWIN_CONDITION
      case twin(Int)
    #endif
  }

  enum Output: Equatable, Sendable {
    #if canImport(Swift)
      case twin(Int)
    #endif
    #if INNOFLOW_UNDEFINED_TWIN_CONDITION
      case twin(String)
    #endif
    case finished(_ result: Int)
    case paired(_ id: Int, _ name: String)
    case mixed(code: Int, _ detail: String)
  }

  var body: some Reducer<State, Action, Output> {
    Reduce { _, _ in .none }
  }
}

/// Owns its phase through `phaseManaged` while composing a child that applies
/// a phase map of its own.
@InnoFlow(phaseManaged: true)
struct DeclarationSiteParent {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
    }

    var phase: Phase = .idle
    var child = DeclarationSiteChild.State()
  }

  enum Action: Equatable, Sendable {
    case load
    case child(DeclarationSiteChild.Action)
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    CombineReducers {
      Reduce<State, Action, Never> { _, _ in .none }
      Scope(
        state: \.child,
        action: Action.childCasePath,
        reducer: DeclarationSiteChild().phaseMap(DeclarationSiteChild.phaseMap)
      )
    }
  }
}

/// The same composition as `DeclarationSiteParent`, spelled with the
/// `OptionalChildLifetime` initializer: `parent:` is this feature's domain and
/// `reducer:` is the child's.
@InnoFlow(phaseManaged: true)
struct DeclarationSiteOptionalParent {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
    }

    var phase: Phase = .idle
    var child: DeclarationSiteChild.State?
  }

  enum Action: Equatable, Sendable {
    case load
    case child(DeclarationSiteChild.Action)
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    OptionalChildLifetime(
      parent: Reduce<State, Action, Never> { state, action in
        if case .load = action {
          state.child = DeclarationSiteChild.State()
        }
        return .none
      },
      state: \.child,
      action: Action.childCasePath,
      instanceID: { $0.instanceID },
      reducer: DeclarationSiteChild().phaseMap(DeclarationSiteChild.phaseMap)
    )
  }
}

private protocol DeprecatedPathExercise {
  static func legacyPathRoundTrips() -> Bool
  static func previousPathRoundTrips() -> Bool
}

private enum LegacyPathExercise: DeprecatedPathExercise {
  @available(*, deprecated, message: "Exercises a deprecated path on purpose")
  static func legacyPathRoundTrips() -> Bool {
    let path = DeclarationSiteFeature.Action.legacyCasePath
    return path.extract(path.embed(.finish)) == .finish
  }

  @available(*, deprecated, message: "Exercises a deprecated path on purpose")
  static func previousPathRoundTrips() -> Bool {
    let path = DeclarationSiteFeature.Action.previousCasePath
    return path.extract(path.embed(.finish)) == .finish
  }
}

@MainActor
@Suite("Macro output follows the declaration site in a real consumer", .timeLimit(.minutes(5)))
struct MacroDeclarationSiteConsumerTests {
  @Test("A feature that states Reducer conformance itself still reduces through its body")
  func statedConformanceFeatureReduces() {
    let store = Store(reducer: StatedConformanceFeature())
    store.send(.increment)
    #expect(store.state.count == 1)
  }

  @Test("Conditional and locally named Action cases have working paths")
  func conditionalAndLocallyNamedCasesHavePaths() {
    typealias Action = DeclarationSiteFeature.Action

    func roundTrips(
      _ path: CasePath<Action, DeclarationSiteChild.Action>
    ) -> Bool {
      path.extract(path.embed(.finish)) == .finish
    }

    #expect(roundTrips(Action.plainCasePath))
    #expect(roundTrips(Action.conditionalCasePath))
    #expect(roundTrips(Action.namedCasePath))
    #expect(Action.plainCasePath.extract(.named(.finish)) == nil)
    #expect(Action.namedCasePath.extract(.plain(.finish)) == nil)
  }

  @Test("A deprecated Action case keeps a path that carries the same deprecation")
  func deprecatedCaseKeepsItsPath() {
    // Reached through the protocol so this test does not itself need an
    // availability attribute to use a deprecated member without a warning.
    let exercise: any DeprecatedPathExercise.Type = LegacyPathExercise.self
    let roundTrips = exercise.legacyPathRoundTrips()
    #expect(roundTrips)
  }

  @Test("A commented or rename-only availability attribute still yields a working path")
  func availabilityLayoutDoesNotBreakThePath() {
    let exercise: any DeprecatedPathExercise.Type = LegacyPathExercise.self
    let previousRoundTrips = exercise.previousPathRoundTrips()
    #expect(previousRoundTrips)

    // The rename was the attribute's only content, so nothing is copied and
    // the path carries no availability of its own.
    let path = DeclarationSiteFeature.Action.renamedOnlyCasePath
    #expect(path.extract(path.embed(.finish)) == .finish)
  }

  @Test("Manual Action paths replace synthesis; an inactive one leaves it in place")
  func manualActionPathsReplaceSynthesis() {
    typealias Action = ManualPathPrecedenceFeature.Action

    func roundTrips(
      _ path: CasePath<Action, DeclarationSiteChild.Action>
    ) -> Bool {
      path.extract(path.embed(.finish)) == .finish
    }

    #expect(roundTrips(Action.namedCasePath))
    #expect(roundTrips(Action.conditionalCasePath))
    #expect(roundTrips(Action.childCasePath))
    #expect(Action.childCasePath.extract(.named(.finish)) == nil)

    let row = Action.rowActionPath.extract(Action.rowActionPath.embed(7, .finish))
    #expect(row?.0 == 7)
    #expect(row?.1 == .finish)
  }

  @Test("One case name repeated across conditions has a path in the active one")
  func repeatedCaseNameHasAPathInTheActiveCondition() {
    let actionPath: CasePath<RepeatedCaseNameFeature.Action, DeclarationSiteChild.Action> =
      RepeatedCaseNameFeature.Action.twinCasePath
    #expect(actionPath.extract(actionPath.embed(.finish)) == .finish)

    let outputPath: CasePath<RepeatedCaseNameFeature.Output, Int> =
      RepeatedCaseNameFeature.Output.twinCasePath
    #expect(outputPath.embed(3) == .twin(3))
    #expect(outputPath.extract(.twin(3)) == 3)
  }

  @Test("Output payloads with a local name synthesize like unlabeled payloads")
  func outputLocalPayloadNamesHavePaths() {
    typealias Output = RepeatedCaseNameFeature.Output

    let finished: CasePath<Output, Int> = Output.finishedCasePath
    #expect(finished.embed(5) == .finished(5))
    #expect(finished.extract(.finished(5)) == 5)

    let paired: CasePath<Output, (Int, String)> = Output.pairedCasePath
    #expect(paired.embed((1, "one")) == .paired(1, "one"))
    #expect(paired.extract(.paired(1, "one"))?.1 == "one")

    let mixed: CasePath<Output, (code: Int, String)> = Output.mixedCasePath
    #expect(mixed.embed((code: 404, "missing")) == .mixed(code: 404, "missing"))
    #expect(mixed.extract(.mixed(code: 404, "missing"))?.code == 404)
    #expect(mixed.extract(.finished(5)) == nil)
  }

  @Test("Parent and child each apply their own phase map")
  func parentAndChildApplyTheirOwnPhaseMaps() {
    let store = Store(reducer: DeclarationSiteParent())

    store.send(.load)
    #expect(store.state.phase == .loading)
    #expect(store.state.child.phase == .idle)

    store.send(.child(.finish))
    #expect(store.state.phase == .loading)
    #expect(store.state.child.phase == .done)
  }

  @Test("The OptionalChildLifetime initializer keeps parent and child phase maps apart")
  func optionalChildInitializerKeepsPhaseMapsApart() {
    let store = Store(reducer: DeclarationSiteOptionalParent())

    store.send(.load)
    #expect(store.state.phase == .loading)
    #expect(store.state.child?.phase == .idle)

    store.send(.child(.finish))
    #expect(store.state.phase == .loading)
    #expect(store.state.child?.phase == .done)
  }
}
