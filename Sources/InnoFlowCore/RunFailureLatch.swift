import Foundation
import os

/// Single-write latch that records whether an effect run's `reportError` hook
/// fired during its lifetime. The Store driver consults the latch after the
/// run's operation closure returns and suppresses the trailing `didFinishRun`
/// when it is set, keeping the `didStartRun`/`didFailRun` pair 1:1 even when
/// `reportError` is invoked from a `@Sendable` closure on a non-main task.
///
/// The latch is intentionally specific to the run-failure signal so the
/// "first-error-wins" contract is documented exactly once, at this type, and
/// is not silently reused for unrelated invariants.
package final class RunFailureLatch: Sendable {
  private let storage = OSAllocatedUnfairLock(initialState: false)

  package init() {}

  /// Atomic compare-and-set: returns `true` only for the call that flipped
  /// the latch from unset to set. Subsequent callers receive `false` so they
  /// can short-circuit duplicate `didFailRun` emissions.
  @discardableResult
  package func setIfUnset() -> Bool {
    storage.withLock { wasSet in
      if wasSet { return false }
      wasSet = true
      return true
    }
  }

  package var isSet: Bool {
    storage.withLock { $0 }
  }
}
