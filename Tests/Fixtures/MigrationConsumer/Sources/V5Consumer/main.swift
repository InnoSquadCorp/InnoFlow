import InnoFlow

@InnoFlow
struct CounterFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
  }

  enum Action: Equatable, Sendable {
    case increment
  }

  var body: some Reducer<State, Action> {
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
struct ChildFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
  }

  enum Action: Equatable, Sendable {
    case increment
  }

  var body: some Reducer<State, Action> {
    Reduce { state, _ in
      state.count += 1
      return .none
    }
  }
}

@InnoFlow
struct ParentFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child = ChildFeature.State()
  }

  enum Action: Equatable, Sendable {
    case child(ChildFeature.Action)
  }

  var body: some Reducer<State, Action> {
    Scope(state: \.child, action: Action.childCasePath, reducer: ChildFeature())
  }
}

@main
struct MigrationConsumer {
  @MainActor
  static func main() {
    let store = Store(reducer: CounterFeature(), initialState: .init())
    store.send(.increment)
    store.send(.increment)
    let selected = store.select(\.count)
    precondition(store.count == 2 && selected.optionalValue == 2)
    var parent: Store<ParentFeature>? = Store(reducer: ParentFeature())
    let child = parent!.scope(state: \.child, action: ParentFeature.Action.childCasePath)
    child.send(.increment)
    precondition(child.count == 1)
    parent = nil
    precondition(child.optionalState == nil)
    print("MIGRATION_COMMON count=2 selected=2")
  }
}
