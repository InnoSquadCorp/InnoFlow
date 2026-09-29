// MARK: - EffectExecutionPolicy.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Admission policy for independent runs that share one Store-local effect ID.
public enum EffectExecutionPolicy: Sendable, Equatable {
  /// Starts the new request after cancelling older eligible work.
  ///
  /// Cancellation is cooperative. An older operation that ignores cancellation
  /// may physically overlap the new run.
  case latest

  /// Rejects a new request while the lane is occupied.
  case dropWhileRunning

  /// Runs requests in admission order with a bounded number of waiting runs.
  ///
  /// `maxPending` excludes the currently-running request and must be non-negative.
  case serial(maxPending: Int)
}

/// The observable admission state of a scheduled effect run.
public enum EffectAdmission: Sendable, Equatable {
  /// The operation owns the lane and is about to begin.
  case started

  /// The operation is waiting behind `position` earlier requests.
  case queued(position: Int)

  /// The operation was not accepted and will never execute.
  case rejected(EffectAdmissionRejection)
}

/// Why a scheduled run was rejected before execution.
public enum EffectAdmissionRejection: Sendable, Equatable {
  /// `dropWhileRunning` found an occupied lane.
  case busy

  /// A serial lane already contains its configured number of pending requests.
  case queueFull(maxPending: Int)

  /// The same live lane was reused with a different execution policy.
  case conflictingPolicy

  /// A serial policy was created with a negative pending capacity.
  case invalidCapacity(Int)
}

extension EffectExecutionPolicy {
  package enum Kind: Sendable, Equatable {
    case latest
    case dropWhileRunning
    case serial(maxPending: Int)
  }

  package var kind: Kind {
    switch self {
    case .latest:
      return .latest
    case .dropWhileRunning:
      return .dropWhileRunning
    case .serial(let maxPending):
      return .serial(maxPending: maxPending)
    }
  }
}
