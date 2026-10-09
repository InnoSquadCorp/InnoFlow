// Test-only shared declarations. Production products do not depend on this target.
import Foundation
import InnoFlow
import InnoFlowCore
import InnoFlowSwiftUI

@InnoFlow
struct ScopedBindableChildFeature {
  struct Child: Equatable, Sendable {
    @BindableField var step = 1
    var title = "Child"
    var note = "Ready"
    var priority = 0
    var isEnabled = true
    var version = 1
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child = Child()
    var unrelated = 0
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
    case setUnrelated(Int)
  }

  enum ChildAction: Equatable, Sendable {
    case setStep(Int)
    case setTitle(String)
    case setNote(String)
    case setPriority(Int)
    case setEnabled(Bool)
    case setVersion(Int)
    case setSnapshot(step: Int, title: String, note: String)
    case setSelectionProbe(
      step: Int,
      title: String,
      note: String,
      priority: Int,
      isEnabled: Bool,
      version: Int
    )
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .child(.setStep(let step)):
        state.child.step = max(1, step)
        return .none

      case .child(.setTitle(let title)):
        state.child.title = title
        return .none

      case .child(.setNote(let note)):
        state.child.note = note
        return .none

      case .child(.setPriority(let priority)):
        state.child.priority = priority
        return .none

      case .child(.setEnabled(let isEnabled)):
        state.child.isEnabled = isEnabled
        return .none

      case .child(.setVersion(let version)):
        state.child.version = version
        return .none

      case .child(.setSnapshot(let step, let title, let note)):
        state.child.step = max(1, step)
        state.child.title = title
        state.child.note = note
        return .none

      case .child(
        .setSelectionProbe(
          let step,
          let title,
          let note,
          let priority,
          let isEnabled,
          let version
        )
      ):
        state.child.step = max(1, step)
        state.child.title = title
        state.child.note = note
        state.child.priority = priority
        state.child.isEnabled = isEnabled
        state.child.version = version
        return .none

      case .setUnrelated(let value):
        state.unrelated = value
        return .none
      }
    }
  }
}

@InnoFlow
struct ScopedCollectionFeature {
  struct Todo: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    @BindableField var isDone = false
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var todos: [Todo] = [
      Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "One"),
      Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Two"),
      Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Three"),
    ]
  }

  enum Action: Equatable, Sendable {
    struct NewTodo: Equatable, Sendable {
      let id: UUID
      let title: String
    }

    case todo(id: UUID, action: TodoAction)
    case moveLastToFront
    case appendTodo(NewTodo)
    case removeTodo(UUID)

    static func todoAction(id: UUID, action: TodoAction) -> Self {
      .todo(id: id, action: action)
    }
  }

  enum TodoAction: Equatable, Sendable {
    case setDone(Bool)
  }

  struct TodoRowFeature: Reducer {
    func reduce(into state: inout Todo, action: TodoAction) -> EffectTask<TodoAction> {
      switch action {
      case .setDone(let isDone):
        state.isDone = isDone
        return .none
      }
    }
  }

  var body: some Reducer<State, Action, Never> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .todo:
          return .none

        case .moveLastToFront:
          guard let last = state.todos.popLast() else { return .none }
          state.todos.insert(last, at: 0)
          return .none

        case .appendTodo(let todo):
          state.todos.append(.init(id: todo.id, title: todo.title))
          return .none

        case .removeTodo(let id):
          state.todos.removeAll { $0.id == id }
          return .none
        }
      }

      ForEachReducer(
        state: \.todos,
        action: Action.todoActionPath,
        reducer: TodoRowFeature()
      )
    }
  }
}

struct BindingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    @BindableField var step = 1
  }

  enum Action: Equatable, Sendable {
    case setStep(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .setStep(let step):
      state.step = max(1, step)
      return .none
    }
  }
}

struct AnimationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case animate(Int)
    case animateRun(Int)
    case _animated(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .animate(let value):
      return EffectTask.send(._animated(value))
        .animation(.easeInOut)

    case .animateRun(let value):
      return EffectTask.run { send in
        await send(._animated(value))
      }
      .animation(.spring())

    case ._animated(let value):
      state.values.append(value)
      return .none
    }
  }
}

struct ComposedAnimationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var value = 0
  }

  enum Action: Equatable, Sendable {
    case trigger(Int)
    case _result(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .trigger(let value):
      return EffectTask.send(._result(value))
        .debounce("animation-debounce", for: .milliseconds(30))
        .animation(.easeInOut)
    case ._result(let value):
      state.value = value
      return .none
    }
  }
}
