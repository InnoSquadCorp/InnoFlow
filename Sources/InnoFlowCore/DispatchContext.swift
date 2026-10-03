import Foundation
import os

/// Process-local, monotonic identity for a root dispatch and its descendants.
/// It is correlation metadata, never a persisted/domain or cross-process ID.
public struct DispatchID: Hashable, Sendable, CustomStringConvertible {
  private static let counter = OSAllocatedUnfairLock(initialState: UInt64(0))
  public let rawValue: UInt64

  public init() {
    rawValue = Self.counter.withLock { value in
      precondition(value < .max, "DispatchID counter exhausted")
      value += 1
      return value
    }
  }

  public var description: String { String(rawValue) }
}
