import Foundation
import InnoFlow
import InnoFlowSwiftUI
import SwiftUI

@InnoFlow
struct PhaseDrivenTodoRowFeature {
  struct State: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    @BindableField var isDone = false

    init(id: UUID = UUID(), title: String, isDone: Bool = false) {
      self.id = id
      self.title = title
      self._isDone = BindableField(wrappedValue: isDone)
    }
  }

  enum Action: Equatable, Sendable {
    case setIsDone(Bool)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setIsDone(let isDone):
        state.isDone = isDone
        return .none
      }
    }
  }
}

typealias SampleTodo = PhaseDrivenTodoRowFeature.State

protocol SampleTodoServiceProtocol: Sendable {
  func loadTodos(shouldFail: Bool) async throws -> [SampleTodo]
}

struct SampleTodoServiceError: LocalizedError, Sendable {
  let errorDescription: String?
}

actor SampleTodoService: SampleTodoServiceProtocol {
  func loadTodos(shouldFail: Bool) async throws -> [SampleTodo] {
    if shouldFail {
      throw SampleTodoServiceError(errorDescription: "Sample network request failed")
    }

    return [
      SampleTodo(title: "Document legal transitions"),
      SampleTodo(title: "Keep navigation out of the phase graph"),
      SampleTodo(title: "Assert transitions with TestStore"),
    ]
  }
}

@InnoFlow(phaseManaged: true)
struct PhaseDrivenTodoFeature {
  struct Dependencies: Sendable {
    let todoService: any SampleTodoServiceProtocol
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: String, Equatable, Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    var phase: Phase = .idle
    var todos: [SampleTodo] = []
    var errorMessage: String?
    @BindableField var shouldFail = false
  }

  enum Action: Equatable, Sendable {
    case loadTodos
    case setShouldFail(Bool)
    case dismissError
    case todo(id: UUID, action: PhaseDrivenTodoRowFeature.Action)
    case _loaded([SampleTodo])
    case _failed(String)
  }

  let dependencies: Dependencies

  init(
    dependencies: Dependencies = .init(
      todoService: SampleTodoService()
    )
  ) {
    self.dependencies = dependencies
  }

  init(todoService: any SampleTodoServiceProtocol) {
    self.init(dependencies: .init(todoService: todoService))
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(.loadTodos, to: .loading)
      }
      From(.loading) {
        On(Action.loadedCasePath, to: .loaded)
        On(Action.failedCasePath, to: .failed)
      }
      From(.loaded) {
        On(.loadTodos, to: .loading)
      }
      From(.failed) {
        On(.loadTodos, to: .loading)
        On(.dismissError, targets: [.idle, .loaded]) { state in
          state.todos.isEmpty ? .idle : .loaded
        }
      }
    }
  }

  static var phaseGraph: PhaseTransitionGraph<State.Phase> {
    phaseMap.derivedGraph
  }

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .loadTodos:
          state.errorMessage = nil
          let shouldFail = state.shouldFail
          let todoService = dependencies.todoService
          return .run { send, context in
            do {
              try await context.sleep(for: .milliseconds(120))
              try await context.checkCancellation()
              let todos = try await todoService.loadTodos(shouldFail: shouldFail)
              await send(._loaded(todos))
            } catch is CancellationError {
              return
            } catch {
              await send(._failed(error.localizedDescription))
            }
          }
          .cancellable("phase-load", cancelInFlight: true)

        case .setShouldFail(let shouldFail):
          state.shouldFail = shouldFail
          return .none

        case .dismissError:
          state.errorMessage = nil
          return .none

        case .todo:
          return .none

        case ._loaded(let todos):
          state.todos = todos
          state.errorMessage = nil
          return .none

        case ._failed(let message):
          state.errorMessage = message
          return .none
        }
      }

      ForEachReducer(
        state: \.todos,
        action: Action.todoActionPath,
        reducer: PhaseDrivenTodoRowFeature()
      )
    }
  }
}

@MainActor
struct PhaseDrivenFSMDemoView: View {
  @State private var store = Store(reducer: PhaseDrivenTodoFeature())

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "A business lifecycle modeled with `@InnoFlow(phaseManaged: true)` and `PhaseMap`: `idle -> loading -> loaded|failed`. Transport and navigation transitions stay outside this phase layer."
        )

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Phase")
              .font(.headline)
            Spacer()
            Text(store.phase.rawValue.capitalized)
              .font(.subheadline.monospaced())
              .foregroundStyle(.secondary)
          }

          Toggle(
            "Fail next load",
            isOn: store.binding(\.$shouldFail, to: PhaseDrivenTodoFeature.Action.setShouldFail)
          )
          .accessibilityIdentifier("phase.fail-next-load")
          .accessibilityHint("Turns the next load request into a failed phase transition")

          Button(store.phase == .loading ? "Loading..." : "Load Todos") {
            store.send(.loadTodos)
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.phase == .loading)
          .accessibilityIdentifier("phase.load-todos")
          .accessibilityLabel(store.phase == .loading ? "Loading todos" : "Load todos")
          .accessibilityHint("Moves the phase graph from idle or loaded into loading")

          if let errorMessage = store.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
              Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("phase.error-message")
              Button("Dismiss Error") {
                store.send(.dismissError)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("phase.dismiss-error")
              .accessibilityHint(
                "Clears the failure message and returns the demo to an interactive state")
            }
          }
        }
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        LogSection(
          title: "Phase Map",
          entries: [
            "idle -> loading",
            "loading -> loaded",
            "loading -> failed",
            "loaded -> loading",
            "failed -> loading",
            "failed -> idle (dismiss with no todos)",
            "failed -> loaded (dismiss with existing todos)",
          ]
        )

        VStack(alignment: .leading, spacing: 12) {
          Text("Todos")
            .font(.headline)

          let todoStores = store.scope(
            collection: \.todos,
            action: PhaseDrivenTodoFeature.Action.todoActionPath
          )

          if todoStores.isEmpty {
            Text("No loaded todos yet.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            ForEach(todoStores) { todoStore in
              PhaseDrivenTodoRowView(store: todoStore)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      .padding()
    }
    .navigationTitle("Phase-Driven FSM")
  }
}

@MainActor
struct PhaseDrivenTodoRowView: View {
  let store: ScopedStore<PhaseDrivenTodoFeature, SampleTodo, PhaseDrivenTodoRowFeature.Action>

  var body: some View {
    Toggle(
      isOn: store.binding(\.$isDone, to: PhaseDrivenTodoRowFeature.Action.setIsDone)
    ) {
      VStack(alignment: .leading, spacing: 4) {
        Text(store.title)
          .foregroundStyle(store.isDone ? .secondary : .primary)
          .strikethrough(store.isDone, color: .secondary)
          .accessibilityIdentifier("phase.todo.\(store.id)")
        Text(store.isDone ? "Completed" : "Pending")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.switch)
    .accessibilityLabel("\(store.title), \(store.isDone ? "completed" : "pending")")
    .accessibilityHint("Marks the todo as complete or pending")
    .padding(.vertical, 4)
  }
}

#Preview("Phase-Driven FSM") {
  NavigationStack {
    PhaseDrivenFSMDemoView()
  }
}
