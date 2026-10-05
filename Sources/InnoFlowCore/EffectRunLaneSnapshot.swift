import Foundation

/// An opaque correlation identity for one live scheduled-run lane.
///
/// It contains no user EffectID, child instance ID, action, state, or output.
/// A later lane created after the prior lane closes has a new identity.
public struct EffectRunLaneID: Hashable, Sendable, CustomStringConvertible {
  private let value: UUID
  package init(_ value: UUID) { self.value = value }
  public var description: String { value.uuidString }
}

/// A payload-free snapshot of a lane's current admission state.
///
/// This describes the current head reservation, not every physically running
/// operation. In particular, a superseded noncooperative latest operation can
/// remain physically active after it no longer owns the lane.
public struct EffectRunLaneSnapshot: Equatable, Sendable {
  public let id: EffectRunLaneID
  public let policy: EffectExecutionPolicy
  public let isStartAdmitted: Bool
  public let pendingRequestCount: Int
  public let isCancellationRequested: Bool

  package init(
    id: EffectRunLaneID,
    policy: EffectExecutionPolicy,
    isStartAdmitted: Bool,
    pendingRequestCount: Int,
    isCancellationRequested: Bool
  ) {
    self.id = id
    self.policy = policy
    self.isStartAdmitted = isStartAdmitted
    self.pendingRequestCount = pendingRequestCount
    self.isCancellationRequested = isCancellationRequested
  }
}

extension Store {
  /// Reads at most `limit` current scheduled-lane admission snapshots.
  ///
  /// Negative and zero limits return an empty array. This is an opt-in,
  /// on-demand diagnostic read: it creates no subscription and retains no
  /// history or reference to this Store. Results contain no raw effect IDs.
  public func runLaneSnapshots(limit: Int = 32) -> [EffectRunLaneSnapshot] {
    effectBridge.runScheduler.snapshots(limit: limit)
  }
}
