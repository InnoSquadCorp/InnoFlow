import InnoFlowCore

struct ConsumerFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var value = 0
    var phase = 0
  }
  enum Action: Equatable, Sendable { case start, response, output }
  typealias Output = Int
  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .start: return .send(.response)
    case .response:
      state.value += 1
      return Self.output(state.value)
    case .output: return Self.output(state.value)
    }
  }
}
