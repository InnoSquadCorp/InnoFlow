import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("EffectTask.perform")
@MainActor
struct EffectTaskPerformTests {
  @Test("maps a successful operation to one action")
  func mapsSuccess() async {
    let store = TestStore(
      reducer: PerformFeature(operation: { 42 })
    )

    await store.send(.start)
    await store.receive(.succeeded(42)) {
      $0.result = .success(42)
    }
    await store.finish()
  }

  @Test("maps a non-cancellation error to one action")
  func mapsFailure() async {
    let store = TestStore(
      reducer: PerformFeature(operation: { throw PerformError.unavailable })
    )

    await store.send(.start)
    await store.receive(.failed("unavailable")) {
      $0.result = .failure("unavailable")
    }
    await store.finish()
  }

  @Test("cancellation does not emit success or failure")
  func cancellationIsSilent() async {
    let store = Store(
      reducer: PerformFeature(operation: {
        try await Task.sleep(for: .seconds(10))
        return 1
      })
    )

    let task = store.send(.start)
    task.cancel()
    await task.finish()

    #expect(store.state.result == nil)
  }
}

private enum PerformError: Error, CustomStringConvertible {
  case unavailable

  var description: String { "unavailable" }
}

private struct PerformFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Result: Equatable, Sendable {
      case success(Int)
      case failure(String)
    }

    var result: Result?

    init() {}
  }

  enum Action: Equatable, Sendable {
    case start
    case succeeded(Int)
    case failed(String)
  }

  let operation: @Sendable () async throws -> Int

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .perform(
        operation: operation,
        success: Action.succeeded,
        failure: { .failed(String(describing: $0)) }
      )

    case .succeeded(let value):
      state.result = .success(value)
      return .none

    case .failed(let message):
      state.result = .failure(message)
      return .none
    }
  }
}
