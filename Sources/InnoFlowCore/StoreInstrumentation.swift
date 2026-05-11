// MARK: - StoreInstrumentation.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import OSLog
public import os

/// Thread-safe slot registry used to pair `runStarted` and `runFinished`
/// callbacks for the signpost adapter. Signpost interval state values must
/// be carried verbatim from begin to end, so the registry stores them inside
/// an `OSAllocatedUnfairLock` slot keyed by the run's UUID token. The
/// callbacks are synchronous fire-and-forget from the store runtime's
/// perspective, so the lock is uncontended in the common case.
final class OSSignpostIntervalStateRegistry: Sendable {
  private let lock = OSAllocatedUnfairLock<[UUID: OSSignpostIntervalState]>(initialState: [:])

  func store(_ state: OSSignpostIntervalState, for token: UUID) {
    lock.withLock { storage in
      storage[token] = state
    }
  }

  func take(token: UUID) -> OSSignpostIntervalState? {
    lock.withLock { storage in
      storage.removeValue(forKey: token)
    }
  }
}

/// Why a produced action was dropped before re-entering the store queue.
public enum ActionDropReason: Sendable, Equatable {
  case storeReleased
  case cancellationBoundary
  case inactiveToken
  case throttledOrDebouncedCancellation
  /// An `IfLet`/`IfCaseLet` composition received a child action while the
  /// child's state was unavailable. Surfaced even in release builds (where
  /// `assertOnly`/`ignore` would otherwise drop silently) so dashboards can
  /// observe parent-child desynchronization.
  case missingChildState
}

/// A unified stream of store instrumentation events.
public enum StoreInstrumentationEvent<Action: Sendable>: Sendable {
  case runStarted(StoreInstrumentation<Action>.RunEvent)
  case runFinished(StoreInstrumentation<Action>.RunEvent)
  case runFailed(StoreInstrumentation<Action>.RunFailedEvent)
  case actionEmitted(StoreInstrumentation<Action>.ActionEvent)
  case actionDropped(StoreInstrumentation<Action>.ActionDropEvent)
  case effectsCancelled(StoreInstrumentation<Action>.CancellationEvent)
}

/// Optional runtime hooks for observing effect execution without changing semantics.
public struct StoreInstrumentation<Action: Sendable>: Sendable {
  public struct RunEvent: Sendable {
    public let token: UUID
    public let cancellationID: AnyEffectID?
    public let sequence: UInt64?

    public init(token: UUID, cancellationID: AnyEffectID?, sequence: UInt64?) {
      self.token = token
      self.cancellationID = cancellationID
      self.sequence = sequence
    }

    public init<ID: Hashable & Sendable>(
      token: UUID,
      cancellationID: EffectID<ID>?,
      sequence: UInt64?
    ) {
      self.init(
        token: token,
        cancellationID: cancellationID.map(AnyEffectID.init),
        sequence: sequence
      )
    }
  }

  public struct ActionEvent: Sendable {
    public let action: Action
    public let cancellationID: AnyEffectID?
    public let sequence: UInt64?

    public init(action: Action, cancellationID: AnyEffectID?, sequence: UInt64?) {
      self.action = action
      self.cancellationID = cancellationID
      self.sequence = sequence
    }

    public init<ID: Hashable & Sendable>(
      action: Action,
      cancellationID: EffectID<ID>?,
      sequence: UInt64?
    ) {
      self.init(
        action: action,
        cancellationID: cancellationID.map(AnyEffectID.init),
        sequence: sequence
      )
    }
  }

  public struct ActionDropEvent: Sendable {
    public let action: Action?
    public let reason: ActionDropReason
    public let cancellationID: AnyEffectID?
    public let sequence: UInt64?

    public init(
      action: Action?,
      reason: ActionDropReason,
      cancellationID: AnyEffectID?,
      sequence: UInt64?
    ) {
      self.action = action
      self.reason = reason
      self.cancellationID = cancellationID
      self.sequence = sequence
    }

    public init<ID: Hashable & Sendable>(
      action: Action?,
      reason: ActionDropReason,
      cancellationID: EffectID<ID>?,
      sequence: UInt64?
    ) {
      self.init(
        action: action,
        reason: reason,
        cancellationID: cancellationID.map(AnyEffectID.init),
        sequence: sequence
      )
    }
  }

  /// An error escaped from `EffectTask.run(...)` work. Carried as descriptions
  /// rather than the raw error because `any Error` is not unconditionally
  /// `Sendable` under Swift 6 strict concurrency, and instrumentation is an
  /// observation hook (e.g., logs, metrics, traces) that does not need to
  /// re-throw or inspect the concrete error type.
  public struct RunFailedEvent: Sendable {
    public let token: UUID
    public let cancellationID: AnyEffectID?
    public let sequence: UInt64?
    public let errorDescription: String
    public let errorTypeName: String

    public init(
      token: UUID,
      cancellationID: AnyEffectID?,
      sequence: UInt64?,
      errorDescription: String,
      errorTypeName: String
    ) {
      self.token = token
      self.cancellationID = cancellationID
      self.sequence = sequence
      self.errorDescription = errorDescription
      self.errorTypeName = errorTypeName
    }

    public init<ID: Hashable & Sendable>(
      token: UUID,
      cancellationID: EffectID<ID>?,
      sequence: UInt64?,
      errorDescription: String,
      errorTypeName: String
    ) {
      self.init(
        token: token,
        cancellationID: cancellationID.map(AnyEffectID.init),
        sequence: sequence,
        errorDescription: errorDescription,
        errorTypeName: errorTypeName
      )
    }
  }

  public struct CancellationEvent: Sendable {
    public let id: AnyEffectID?
    public let sequence: UInt64

    public init(id: AnyEffectID?, sequence: UInt64) {
      self.id = id
      self.sequence = sequence
    }

    public init<ID: Hashable & Sendable>(id: EffectID<ID>?, sequence: UInt64) {
      self.init(id: id.map(AnyEffectID.init), sequence: sequence)
    }
  }

  public var didStartRun: @Sendable (RunEvent) -> Void
  public var didFinishRun: @Sendable (RunEvent) -> Void
  public var didFailRun: @Sendable (RunFailedEvent) -> Void
  public var didEmitAction: @Sendable (ActionEvent) -> Void
  public var didDropAction: @Sendable (ActionDropEvent) -> Void
  public var didCancelEffects: @Sendable (CancellationEvent) -> Void

  public init(
    didStartRun: @escaping @Sendable (RunEvent) -> Void = { _ in },
    didFinishRun: @escaping @Sendable (RunEvent) -> Void = { _ in },
    didFailRun: @escaping @Sendable (RunFailedEvent) -> Void = { _ in },
    didEmitAction: @escaping @Sendable (ActionEvent) -> Void = { _ in },
    didDropAction: @escaping @Sendable (ActionDropEvent) -> Void = { _ in },
    didCancelEffects: @escaping @Sendable (CancellationEvent) -> Void = { _ in }
  ) {
    self.didStartRun = didStartRun
    self.didFinishRun = didFinishRun
    self.didFailRun = didFailRun
    self.didEmitAction = didEmitAction
    self.didDropAction = didDropAction
    self.didCancelEffects = didCancelEffects
  }

  public static var disabled: Self {
    .init()
  }

  public static func sink(
    _ receive: @escaping @Sendable (StoreInstrumentationEvent<Action>) -> Void
  ) -> Self {
    .init(
      didStartRun: { receive(.runStarted($0)) },
      didFinishRun: { receive(.runFinished($0)) },
      didFailRun: { receive(.runFailed($0)) },
      didEmitAction: { receive(.actionEmitted($0)) },
      didDropAction: { receive(.actionDropped($0)) },
      didCancelEffects: { receive(.effectsCancelled($0)) }
    )
  }

  public static func combined(_ instrumentations: Self...) -> Self {
    .init(
      didStartRun: { event in
        for instrumentation in instrumentations {
          instrumentation.didStartRun(event)
        }
      },
      didFinishRun: { event in
        for instrumentation in instrumentations {
          instrumentation.didFinishRun(event)
        }
      },
      didFailRun: { event in
        for instrumentation in instrumentations {
          instrumentation.didFailRun(event)
        }
      },
      didEmitAction: { event in
        for instrumentation in instrumentations {
          instrumentation.didEmitAction(event)
        }
      },
      didDropAction: { event in
        for instrumentation in instrumentations {
          instrumentation.didDropAction(event)
        }
      },
      didCancelEffects: { event in
        for instrumentation in instrumentations {
          instrumentation.didCancelEffects(event)
        }
      }
    )
  }

  /// Bridges store instrumentation to `OSSignposter`, surfacing run lifecycle
  /// inside Instruments without changing reducer or effect semantics.
  ///
  /// Each `.runStarted` event opens an interval signpost named after the
  /// supplied `name`, identified by the run's UUID token. The matching
  /// `.runFinished` event closes the same interval. Action emissions and
  /// cancellations are surfaced as `emitEvent` signposts on the same name
  /// so they appear inline with the interval in Instruments' timeline.
  ///
  /// Pair with the existing `.osLog(logger:)` adapter through `.combined(...)`
  /// when you want both Console-readable output and signpost-driven Instruments
  /// traces from the same store.
  ///
  /// Action and error payloads are redacted by default because
  /// `String(describing:)` and error descriptions can expose user data in
  /// Instruments traces. Opt in with `includeActions: true` and
  /// `includeErrorPayload: true` only for local debugging sessions where payload
  /// visibility is intentional.
  public static func signpost(
    signposter: OSSignposter,
    name: StaticString = "InnoFlow.run",
    includeActions: Bool = false,
    includeErrorPayload: Bool = false
  ) -> Self {
    let intervalStates = OSSignpostIntervalStateRegistry()

    return .init(
      didStartRun: { event in
        let state = signposter.beginInterval(
          name,
          id: signposter.makeSignpostID(),
          "token=\(event.token.uuidString) cancellationID=\(String(describing: event.cancellationID)) sequence=\(String(describing: event.sequence))"
        )
        intervalStates.store(state, for: event.token)
      },
      didFinishRun: { event in
        guard let state = intervalStates.take(token: event.token) else { return }
        signposter.endInterval(
          name,
          state,
          "token=\(event.token.uuidString) cancellationID=\(String(describing: event.cancellationID)) sequence=\(String(describing: event.sequence))"
        )
      },
      didFailRun: { event in
        // Close the interval so signposter pairing remains balanced even when
        // the run terminates abnormally, then surface the failure as an event.
        if let state = intervalStates.take(token: event.token) {
          signposter.endInterval(
            name,
            state,
            "token=\(event.token.uuidString) failed cancellationID=\(String(describing: event.cancellationID)) sequence=\(String(describing: event.sequence))"
          )
        }
        let renderedErrorDescription =
          includeErrorPayload ? event.errorDescription : "<redacted>"
        signposter.emitEvent(
          name,
          id: .exclusive,
          "fail token=\(event.token.uuidString) errorType=\(event.errorTypeName) errorDescription=\(renderedErrorDescription) cancellationID=\(String(describing: event.cancellationID)) sequence=\(String(describing: event.sequence))"
        )
      },
      didEmitAction: { event in
        let actionDescription =
          includeActions ? String(describing: event.action) : "<redacted>"
        signposter.emitEvent(
          name,
          id: .exclusive,
          "emit action=\(actionDescription) cancellationID=\(String(describing: event.cancellationID)) sequence=\(String(describing: event.sequence))"
        )
      },
      didDropAction: { event in
        let renderedAction =
          includeActions ? event.action.map(String.init(describing:)) ?? "<none>" : "<redacted>"
        signposter.emitEvent(
          name,
          id: .exclusive,
          "drop action=\(renderedAction) reason=\(String(describing: event.reason)) cancellationID=\(String(describing: event.cancellationID)) sequence=\(String(describing: event.sequence))"
        )
      },
      didCancelEffects: { event in
        signposter.emitEvent(
          name,
          id: .exclusive,
          "cancel id=\(String(describing: event.id)) sequence=\(event.sequence)"
        )
      }
    )
  }

  /// Bridges store instrumentation to `Logger` for Console-readable runtime
  /// events.
  ///
  /// Action payloads are redacted by default. Set `includeActions` to `true`
  /// only when action descriptions are safe to expose in public Console output.
  public static func osLog(
    logger: Logger,
    includeActions: Bool = false
  ) -> Self {
    .sink { event in
      switch event {
      case .runStarted(let runEvent):
        logger.debug(
          "InnoFlow run started token=\(runEvent.token.uuidString, privacy: .public) cancellationID=\(String(describing: runEvent.cancellationID), privacy: .public) sequence=\(String(describing: runEvent.sequence), privacy: .public)"
        )

      case .runFinished(let runEvent):
        logger.debug(
          "InnoFlow run finished token=\(runEvent.token.uuidString, privacy: .public) cancellationID=\(String(describing: runEvent.cancellationID), privacy: .public) sequence=\(String(describing: runEvent.sequence), privacy: .public)"
        )

      case .runFailed(let failedEvent):
        logger.error(
          "InnoFlow run failed token=\(failedEvent.token.uuidString, privacy: .public) errorType=\(failedEvent.errorTypeName, privacy: .public) errorDescription=\(failedEvent.errorDescription, privacy: .private) cancellationID=\(String(describing: failedEvent.cancellationID), privacy: .public) sequence=\(String(describing: failedEvent.sequence), privacy: .public)"
        )

      case .actionEmitted(let actionEvent):
        let actionDescription =
          includeActions ? String(describing: actionEvent.action) : "<redacted>"
        logger.debug(
          "InnoFlow emitted action=\(actionDescription, privacy: .public) cancellationID=\(String(describing: actionEvent.cancellationID), privacy: .public) sequence=\(String(describing: actionEvent.sequence), privacy: .public)"
        )

      case .actionDropped(let dropEvent):
        let renderedAction =
          includeActions ? dropEvent.action.map(String.init(describing:)) ?? "<none>" : "<redacted>"
        logger.debug(
          "InnoFlow dropped action=\(renderedAction, privacy: .public) reason=\(String(describing: dropEvent.reason), privacy: .public) cancellationID=\(String(describing: dropEvent.cancellationID), privacy: .public) sequence=\(String(describing: dropEvent.sequence), privacy: .public)"
        )

      case .effectsCancelled(let cancellationEvent):
        logger.debug(
          "InnoFlow cancelled effects id=\(String(describing: cancellationEvent.id), privacy: .public) sequence=\(cancellationEvent.sequence, privacy: .public)"
        )
      }
    }
  }
}
