// MARK: - EffectInstrumentationWitness.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import os

@testable import InnoFlow

struct EffectInstrumentationWitnessSnapshot: Sendable {
  let runStartedCount: UInt64
  let runFinishedCount: UInt64
  let cancellationCount: UInt64
  let matchedRunPairs: Int
}

final class EffectInstrumentationWitness: Sendable {
  private enum RunKey: Hashable, Sendable {
    case sequence(UInt64)
    case token(UUID)
  }

  private struct State: Sendable {
    var runStartedCount: UInt64 = 0
    var runFinishedCount: UInt64 = 0
    var cancellationCount: UInt64 = 0
    var phaseMaskByRunKey: [RunKey: UInt8] = [:]
  }

  private static let runStartedMask: UInt8 = 1 << 0
  private static let runFinishedMask: UInt8 = 1 << 1

  private let state = OSAllocatedUnfairLock<State>(initialState: .init())

  func instrumentation<Action: Sendable>() -> StoreInstrumentation<Action> {
    .sink { [self] event in
      switch event {
      case .runStarted(let runEvent):
        recordRunStarted(key: runKey(for: runEvent))

      case .runFinished(let runEvent):
        recordRunFinished(key: runKey(for: runEvent))

      case .effectsCancelled:
        recordCancellation()

      case .actionEmitted, .actionDropped, .runFailed:
        break
      }
    }
  }

  func snapshot() -> EffectInstrumentationWitnessSnapshot {
    state.withLock { state in
      let matchedRunPairs = state.phaseMaskByRunKey.values.reduce(into: 0) { count, phaseMask in
        if phaseMask & Self.runStartedMask != 0 && phaseMask & Self.runFinishedMask != 0 {
          count += 1
        }
      }
      return .init(
        runStartedCount: state.runStartedCount,
        runFinishedCount: state.runFinishedCount,
        cancellationCount: state.cancellationCount,
        matchedRunPairs: matchedRunPairs
      )
    }
  }

  private func recordRunStarted(key: RunKey) {
    state.withLock { state in
      state.runStartedCount &+= 1
      state.phaseMaskByRunKey[key, default: 0] |= Self.runStartedMask
    }
  }

  private func recordRunFinished(key: RunKey) {
    state.withLock { state in
      state.runFinishedCount &+= 1
      state.phaseMaskByRunKey[key, default: 0] |= Self.runFinishedMask
    }
  }

  private func recordCancellation() {
    state.withLock { state in
      state.cancellationCount &+= 1
    }
  }

  private func runKey<Action>(for event: StoreInstrumentation<Action>.RunEvent) -> RunKey {
    if let sequence = event.sequence {
      return .sequence(sequence)
    }
    return .token(event.token)
  }
}
