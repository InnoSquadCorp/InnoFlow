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
  private struct State {
    var runStartedCount: UInt64 = 0
    var runFinishedCount: UInt64 = 0
    var cancellationCount: UInt64 = 0
    var phaseMaskBySequence: [UInt64: UInt8] = [:]
  }

  private static let runStartedMask: UInt8 = 1 << 0
  private static let runFinishedMask: UInt8 = 1 << 1

  private let state = OSAllocatedUnfairLock<State>(initialState: .init())

  func instrumentation<Action: Sendable>() -> StoreInstrumentation<Action> {
    .sink { [self] event in
      switch event {
      case .runStarted(let runEvent):
        recordRunStarted(sequence: runEvent.sequence ?? 0)

      case .runFinished(let runEvent):
        recordRunFinished(sequence: runEvent.sequence ?? 0)

      case .effectsCancelled:
        recordCancellation()

      case .actionEmitted, .actionDropped:
        break
      }
    }
  }

  func snapshot() -> EffectInstrumentationWitnessSnapshot {
    state.withLock { state in
      let matchedRunPairs = state.phaseMaskBySequence.values.reduce(into: 0) { count, phaseMask in
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

  private func recordRunStarted(sequence: UInt64) {
    state.withLock { state in
      state.runStartedCount &+= 1
      state.phaseMaskBySequence[sequence, default: 0] |= Self.runStartedMask
    }
  }

  private func recordRunFinished(sequence: UInt64) {
    state.withLock { state in
      state.runFinishedCount &+= 1
      state.phaseMaskBySequence[sequence, default: 0] |= Self.runFinishedMask
    }
  }

  private func recordCancellation() {
    state.withLock { state in
      state.cancellationCount &+= 1
    }
  }
}
