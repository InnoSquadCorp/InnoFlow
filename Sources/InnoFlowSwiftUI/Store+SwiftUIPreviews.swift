// MARK: - Store+SwiftUIPreviews.swift
// InnoFlow - SwiftUI preview conveniences
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlow

extension Store {
  /// Creates a store for SwiftUI previews with an explicit preview state.
  public static func preview(
    reducer: R,
    initialState: R.State,
    clock: StoreClock = .continuous,
    instrumentation: StoreInstrumentation<R.Action> = .disabled
  ) -> Store<R> {
    Store(
      reducer: reducer,
      initialState: initialState,
      clock: clock,
      instrumentation: instrumentation
    )
  }

  /// Creates a store for SwiftUI previews using `DefaultInitializable` state.
  public static func preview(
    reducer: R,
    clock: StoreClock = .continuous,
    instrumentation: StoreInstrumentation<R.Action> = .disabled
  ) -> Store<R> where R.State: DefaultInitializable {
    Store(
      reducer: reducer,
      clock: clock,
      instrumentation: instrumentation
    )
  }
}
