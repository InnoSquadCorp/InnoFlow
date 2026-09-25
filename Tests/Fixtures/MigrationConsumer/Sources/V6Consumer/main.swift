import InnoFlow

@InnoFlow
struct CounterFeature {
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
struct ChildFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
  }

  enum Action: Equatable, Sendable {
    case increment
  }

  var body: some Reducer<State, Action, Never> {
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

  var body: some Reducer<State, Action, Never> {
    Scope(state: \.child, action: Action.childCasePath, reducer: ChildFeature())
  }
}

@InnoFlow
struct OutputFeature {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case select(Int)
  }

  enum Output: Equatable, Sendable {
    case selected(Int)
  }

  var body: some Reducer<State, Action, Output> {
    Reduce { _, action in
      switch action {
      case .select(let id):
        Self.output(.selected(id))
      }
    }
  }
}

@main
struct MigrationConsumer {
  @MainActor
  static func main() async {
    let store = Store(reducer: CounterFeature(), initialState: .init())
    await store.send(.increment).finish()
    await store.send(.increment).finish()
    let selected = store.select(\.count)
    precondition(store.count == 2 && selected.optionalValue == 2)
    let selections = [1, 2].map { offset in
      store.select(dependingOn: \.count) { $0 + offset }
    }
    precondition(selections[0] !== selections[1])
    precondition(selections[0].optionalValue == 3 && selections[1].optionalValue == 4)
    let named = [1, 2].map { _ in
      store.select(dependingOn: \.count, id: "count-plus-one") { $0 + 1 }
    }
    precondition(named[0] === named[1])
    var parent: Store<ParentFeature>? = Store(reducer: ParentFeature())
    let child = parent!.scope(state: \.child, action: ParentFeature.Action.childCasePath)
    await child.send(.increment).finish()
    precondition(child.count == 1)
    parent = nil
    precondition(child.optionalState == nil)

    let outputStore = Store(reducer: OutputFeature())
    let outputTask = outputStore.send(.select(42), capturingOutputs: .unbounded)
    var outputIterator = outputTask.outputs.makeAsyncIterator()
    await outputTask.finish()
    let output = await outputIterator.next()
    precondition(output == .selected(42))
    print("MIGRATION_COMMON count=2 selected=2")
    print("MIGRATION_V6 independent=3,4 named-reused=true scope-released=true output=42")
  }
}
