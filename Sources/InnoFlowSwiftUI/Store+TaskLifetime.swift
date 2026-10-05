@_exported public import InnoFlowCore
public import SwiftUI

extension View {
  /// Starts one view-owned dispatch. Disappearance cancels only that dispatch
  /// and joins physical work; sibling dispatches and the Store stay alive.
  @MainActor
  public func innoFlowTask<R: Reducer>(_ store: Store<R>, action: R.Action) -> some View {
    task { @MainActor in
      await runStoreDispatchLifetime(store: store, action: action)
    }
  }

  /// Restarts one view-owned dispatch when SwiftUI observes a changed ID.
  /// Uncooperative old operations remain tracked until they physically return.
  @MainActor
  public func innoFlowTask<R: Reducer, ID: Equatable & Sendable>(
    _ store: Store<R>, id: ID, action: R.Action
  ) -> some View {
    task(id: id) { @MainActor in
      await runStoreDispatchLifetime(store: store, action: action)
    }
  }
}
