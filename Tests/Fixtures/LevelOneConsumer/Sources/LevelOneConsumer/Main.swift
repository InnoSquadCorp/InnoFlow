import InnoFlow
import InnoFlowTesting

@InnoFlow
struct Counter {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    @BindableField var step = 1
  }
  enum Action: Equatable, Sendable {
    case increment
    case setStep(Int)
  }
  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .increment: state.count += state.step
      case .setStep(let value): state.step = value
      }
      return .none
    }
  }
}
@main struct LevelOneConsumer {
  @MainActor static func main() async {
    let store = Store(reducer: Counter())
    store.send(.increment)
    precondition(store.state.count == 1)
    let test = TestStore(reducer: Counter())
    await test.send(.setStep(2)) { $0.step = 2 }
    await test.send(.increment) { $0.count = 2 }
    await test.finish()
    precondition(test.state.count == 2 && test.state.step == 2)
    print("Level 1 consumer passed")
  }
}
