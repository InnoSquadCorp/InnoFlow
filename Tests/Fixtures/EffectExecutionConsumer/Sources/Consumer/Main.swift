import Foundation
import Dispatch
import InnoFlowCore

struct IsolationState: Sendable { var completed: [Int] = [] }
enum IsolationAction: Sendable { case start, complete(Int) }
func verifyGenericExecutor() { dispatchPrecondition(condition: .notOnQueue(.main)) }
@main struct ConcurrentEffectConsumer {
  @MainActor static func main() async {
    let reducer = Reduce<IsolationState, IsolationAction, Never> { state, action in
      switch action {
      case .start:
        return .merge(
          .run { send in
            verifyGenericExecutor()
            await send(.complete(1))
          },
          .perform(operation: {
            verifyGenericExecutor()
            return 2
          }, success: { .complete($0) }, failure: { _ in .complete(-1) }),
          .run(id: EffectID("isolation"), policy: .serial(maxPending: UInt(1))) { send, _ in
            verifyGenericExecutor()
            await send(.complete(3))
          }
        )
      case .complete(let value):
        state.completed.append(value)
        return .none
      }
    }
    let store = Store(reducer: reducer, initialState: .init())
    await store.send(.start).finish()
    precondition(store.state.completed.sorted() == [1, 2, 3])
    print("run + perform + scheduled operation executed off the main dispatch queue")
  }
}

// A function-value spelling remains accepted under either module default.
func acceptOperation(_ operation: @escaping @Sendable (Send<IsolationAction>, EffectContext) async -> Void)
  -> EffectTask<IsolationAction>
{
  .run(operation)
}

func admissionDescription(_ admission: EffectAdmission) -> String {
  switch admission {
  case .started: "started"
  case .queued: "queued"
  case .rejected: "rejected"
  case .cancelledBeforeStart: "cancelled before start"
  case .superseded: "superseded"
  }
}
