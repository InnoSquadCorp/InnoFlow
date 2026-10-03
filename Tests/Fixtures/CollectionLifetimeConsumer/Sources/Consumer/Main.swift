import InnoFlowCore

enum Selection: Sendable { case active(Int) }
enum Action: Sendable { case value(Int) }
typealias ChildReducer = Reduce<Int, Int, Never>
typealias CaseReducer = IfCaseLet<Selection, Action, ChildReducer>

func makeCase(
  state: CasePath<Selection, Int>, action: CasePath<Action, Int>, child: ChildReducer
) -> CaseReducer {
  // Existing call syntax remains accepted with caller-defaulted coordinates.
  IfCaseLet(state: state, action: action, reducer: child, onMissing: .ignore)
}

func makeIdentifiedCase<ID: Hashable & Sendable>(
  state: CasePath<Selection, Int>, action: CasePath<Action, Int>, child: ChildReducer,
  id: EffectID<ID>
) -> CaseReducer {
  IfCaseLet(state: state, action: action, reducer: child, lifetimeID: id)
}

func makeAdapter() -> (
  CasePath<Selection, Int>, CasePath<Action, Int>, ChildReducer, OnMissingPolicy
) -> CaseReducer {
  { state, action, child, policy in
    IfCaseLet(state: state, action: action, reducer: child, onMissing: policy)
  }
}

@main struct Consumer {
  @MainActor static func main() async {
    let state = CasePath<Selection, Int>(
      embed: { .active($0) },
      extract: { if case .active(let value) = $0 { value } else { nil } })
    let action = CasePath<Action, Int>(
      embed: { .value($0) },
      extract: { if case .value(let value) = $0 { value } else { nil } })
    let child = ChildReducer { state, value in
      state += value
      return .none
    }
    let reducers = [
      makeCase(state: state, action: action, child: child),
      makeIdentifiedCase(state: state, action: action, child: child, id: EffectID("case")),
      makeAdapter()(state, action, child, .ignore),
    ]
    for reducer in reducers {
      let store = Store(reducer: reducer, initialState: .active(1))
      await store.send(.value(2)).finish()
      guard case .active(3) = store.state else { preconditionFailure("case reducer did not run") }
    }
    print("IfCaseLet existing calls, explicit lifetime IDs, and initializer adapter passed")
  }
}
