// Shared by SwiftUI modifiers and Core-only lifecycle contract tests.
@MainActor
package func runStoreDispatchLifetime<R: Reducer>(store: Store<R>, action: R.Action) async {
  guard !Task.isCancelled else { return }
  let dispatch = store.send(action)
  // finish cancels only this dispatch when its caller is cancelled and joins
  // physical work, including operations that ignore cooperative cancellation.
  await dispatch.finish()
}
