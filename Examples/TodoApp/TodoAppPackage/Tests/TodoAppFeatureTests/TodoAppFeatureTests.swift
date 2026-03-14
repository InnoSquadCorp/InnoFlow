import Foundation
import Testing
import InnoFlowTesting

@testable import TodoAppFeature

private struct FailingTodoService: TodoServiceProtocol {
  let message: String

  func loadTodos() async throws -> [Todo] {
    struct LoadError: LocalizedError {
      let errorDescription: String?
    }
    throw LoadError(errorDescription: message)
  }

  func saveTodos(_ todos: [Todo]) async throws {
    _ = todos
  }
}

@Suite("TodoFeature phase-driven tests")
struct TodoFeatureTests {
  @Test("load success follows the documented phase graph")
  @MainActor
  func loadSuccessFollowsPhaseGraph() async {
    let todo = Todo(title: "Write tests")
    let store = TestStore(
      reducer: TodoFeature(
        todoService: MockTodoService(
          todos: [todo]
        )
      )
    )

    await store.send(.loadTodos, tracking: \.phase, through: TodoFeature.phaseGraph) {
      $0.phase = .loading
      $0.errorMessage = nil
    }

    await store.receive(._todosLoaded([todo]), tracking: \.phase, through: TodoFeature.phaseGraph) {
      $0.phase = .loaded
      $0.todos = [todo]
      $0.errorMessage = nil
    }

    await store.assertNoMoreActions()
  }

  @Test("load failure can recover back to idle after dismissing the alert")
  @MainActor
  func loadFailureCanRecoverToIdle() async {
    let store = TestStore(
      reducer: TodoFeature(
        todoService: FailingTodoService(message: "network down")
      )
    )

    await store.send(.loadTodos, tracking: \.phase, through: TodoFeature.phaseGraph) {
      $0.phase = .loading
      $0.errorMessage = nil
    }

    await store.receive(._loadFailed("network down"), tracking: \.phase, through: TodoFeature.phaseGraph) {
      $0.phase = .failed
      $0.errorMessage = "network down"
    }

    await store.send(.dismissError) {
      $0.phase = .idle
      $0.errorMessage = nil
    }
  }
}

private struct MockTodoService: TodoServiceProtocol {
  let todos: [Todo]

  func loadTodos() async throws -> [Todo] {
    todos
  }

  func saveTodos(_ todos: [Todo]) async throws {
    _ = todos
  }
}
