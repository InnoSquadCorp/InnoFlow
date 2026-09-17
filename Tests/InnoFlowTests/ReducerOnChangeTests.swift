import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("Reducer.onChange")
@MainActor
struct ReducerOnChangeTests {
  @Test("emits an effect only when the selected value changes")
  func emitsOnlyForChanges() async {
    let store = TestStore(reducer: OnChangeFeature())

    await store.send(.setName("Inno")) {
      $0.name = "Inno"
    }
    await store.receive(.persist(old: "", new: "Inno")) {
      $0.persistedNames = ["Inno"]
    }

    await store.send(.setName("Inno"))
    await store.finish()
  }

  @Test("merges the base effect with the change effect")
  func mergesBaseAndChangeEffects() async {
    let store = TestStore(reducer: OnChangeFeature())

    await store.send(.setAndValidate("Flow")) {
      $0.name = "Flow"
    }
    await store.receive(.validated("Flow")) {
      $0.validatedNames = ["Flow"]
    }
    await store.receive(.persist(old: "", new: "Flow")) {
      $0.persistedNames = ["Flow"]
    }
    await store.finish()
  }
}

private struct OnChangeFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var name = ""
    var persistedNames: [String] = []
    var validatedNames: [String] = []

    init() {}
  }

  enum Action: Equatable, Sendable {
    case setName(String)
    case setAndValidate(String)
    case persist(old: String, new: String)
    case validated(String)
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .setName(let name):
        state.name = name
        return .none

      case .setAndValidate(let name):
        state.name = name
        return .send(.validated(name))

      case .persist(_, let new):
        state.persistedNames.append(new)
        return .none

      case .validated(let name):
        state.validatedNames.append(name)
        return .none
      }
    }
    .onChange(of: \.name) { old, new in
      .send(.persist(old: old, new: new))
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    body.reduce(into: &state, action: action)
  }
}
