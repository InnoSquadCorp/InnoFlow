import Foundation
import InnoFlow

@InnoFlow
struct LifetimeExampleChild {
  struct State: Equatable, Sendable {
    let instanceID: UUID
    let businessID: Int
    var isLoading = false
  }
  enum Action: Equatable, Sendable { case load, loaded }
  enum Output: Equatable, Sendable { case loaded(Int) }
  var body: some Reducer<State, Action, Output> {
    Reduce { state, action in
      switch action {
      case .load:
        state.isLoading = true
        return .run { send, context in
          // Deliberately attempt a late response after cancellation. The
          // runtime's captured child owner must reject it on re-entry.
          do { try await context.sleep(for: .seconds(1)) } catch {}
          await send(.loaded)
        }
      case .loaded:
        state.isLoading = false
        return Self.output(.loaded(state.businessID))
      }
    }
  }
}

@InnoFlow
struct OptionalChildLifetimeExample {
  struct State: Equatable, Sendable, DefaultInitializable {
    var child: LifetimeExampleChild.State?
  }
  enum Action: Equatable, Sendable {
    case open(Int)
    case close
    case child(LifetimeExampleChild.Action)
  }
  enum Output: Equatable, Sendable { case loaded(Int) }
  var body: some Reducer<State, Action, Output> {
    Reduce<State, Action, Output> { state, action in
      switch action {
      case .open(let id): state.child = .init(instanceID: UUID(), businessID: id)
      case .close: state.child = nil
      case .child: break
      }
      return .none
    }.optionalChild(
      state: \.child, action: Action.childCasePath,
      instanceID: { $0.instanceID },
      child: LifetimeExampleChild().mapOutput { output in
        switch output {
        case .loaded(let id): .loaded(id)
        }
      }
    )
  }
}
