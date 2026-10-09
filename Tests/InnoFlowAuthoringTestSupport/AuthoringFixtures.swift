// Test-only shared declarations. Production products do not depend on this target.
import Foundation
import InnoFlow

@testable import InnoFlowCore

struct GenericExtensionNamespace<Value: Equatable & Sendable> {}

extension GenericExtensionNamespace {
  @InnoFlow
  struct Feature {
    struct State: Equatable, Sendable, DefaultInitializable {
      var value: Value?
      init() {}
    }

    enum Action: Equatable, Sendable {
      case replace(Value)
      case child(id: Int, action: Value)
    }

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
}

@InnoFlow
struct GenericCollectionScopeFeature<Value: Equatable & Sendable> {
  struct Row: Equatable, Identifiable, Sendable {
    let id: Int
    var value: Value?
  }

  struct State: Equatable, Sendable {
    var rows = [Row(id: 0)]
  }

  enum Action: Equatable, Sendable {
    case row(id: Int, action: Value)
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .row(let id, let value):
        guard let index = state.rows.firstIndex(where: { $0.id == id }) else {
          return .none
        }
        state.rows[index].value = value
        return .none
      }
    }
  }
}

@InnoFlow
struct ScopedTestHarnessFeature {
  struct Child: Equatable, Sendable {
    var log: [String] = []
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child = Child()
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case start
    case finished
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .child(.start):
        state.child.log.append("start")
        return .send(.child(.finished))

      case .child(.finished):
        state.child.log.append("finished")
        return .none
      }
    }
  }
}

protocol DependencyBundleServiceProtocol: Sendable {
  func message() async -> String
}

actor DependencyBundleService: DependencyBundleServiceProtocol {
  private let value: String

  init(value: String = "bundle-ready") {
    self.value = value
  }

  func message() async -> String {
    value
  }
}

@InnoFlow
struct DependencyBundleFeature {
  struct Dependencies: Sendable {
    let service: any DependencyBundleServiceProtocol
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var output = ""
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
  }

  let dependencies: Dependencies

  init(service: any DependencyBundleServiceProtocol = DependencyBundleService()) {
    self.dependencies = .init(service: service)
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .load:
        let service = dependencies.service
        return .run { send, _ in
          let value = await service.message()
          await send(._loaded(value))
        }

      case ._loaded(let value):
        state.output = value
        state.log.append("loaded \(value)")
        return .none
      }
    }
  }
}

@InnoFlow
struct IfLetFeature {
  struct Child: Equatable, Sendable {
    var count = 0
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child: Child? = .init()
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
    case dismiss
    case present
  }

  enum ChildAction: Equatable, Sendable {
    case increment
    case finished
  }

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .send(.finished)

      case .finished:
        return .none
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .dismiss:
          state.child = nil
          return .none

        case .present:
          state.child = .init()
          return .none

        case .child(.finished):
          state.log.append("optional-finished")
          return .none

        case .child:
          return .none
        }
      }

      IfLet(
        state: \.child,
        action: Action.childCasePath,
        reducer: ChildReducer()
      )
    }
  }
}

@InnoFlow
struct IfCaseLetFeature {
  struct Child: Equatable, Sendable {
    var count = 0
    var completions = 0
  }

  enum State: Equatable, Sendable, DefaultInitializable {
    case idle
    case child(Child)

    init() {
      self = .idle
    }
  }

  enum Action: Equatable, Sendable {
    case activate
    case deactivate
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case increment
    case finished
  }

  static let childStateCasePath = CasePath<State, Child>(
    embed: State.child,
    extract: { state in
      guard case .child(let child) = state else { return nil }
      return child
    }
  )

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .send(.finished)

      case .finished:
        return .none
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .activate:
          state = .child(.init())
          return .none

        case .deactivate:
          state = .idle
          return .none

        case .child(.finished):
          guard case .child(var child) = state else { return .none }
          child.completions += 1
          state = .child(child)
          return .none

        case .child:
          return .none
        }
      }

      IfCaseLet(
        state: Self.childStateCasePath,
        action: Action.childCasePath,
        reducer: ChildReducer()
      )
    }
  }
}

@InnoFlow
struct IfLetIgnoreFeature {
  struct Child: Equatable, Sendable {
    var count = 0
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child: Child? = .init()
    var untouched: Int = 7
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case increment
  }

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .none
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    IfLet(
      state: \.child,
      action: Action.childCasePath,
      reducer: ChildReducer(),
      onMissing: .ignore
    )
  }
}

@InnoFlow
struct IfCaseLetIgnoreFeature {
  struct Child: Equatable, Sendable {
    var count = 0
  }

  enum State: Equatable, Sendable, DefaultInitializable {
    case idle
    case child(Child)

    init() { self = .idle }
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case increment
  }

  static let childStateCasePath = CasePath<State, Child>(
    embed: State.child,
    extract: { state in
      guard case .child(let child) = state else { return nil }
      return child
    }
  )

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .none
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    IfCaseLet(
      state: Self.childStateCasePath,
      action: Action.childCasePath,
      reducer: ChildReducer(),
      onMissing: .ignore
    )
  }
}

@InnoFlow(phaseManaged: true)
struct PhaseManagedFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    var phase: Phase = .idle
    var output: String?
    var errorMessage: String?
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
    case _failed(String)
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(Action.loadedCasePath, to: .loaded)
        On(Action.failedCasePath, to: .failed)
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .load:
        state.errorMessage = nil
        return .none
      case ._loaded(let output):
        state.output = output
        return .none
      case ._failed(let message):
        state.errorMessage = message
        return .none
      }
    }
  }
}
