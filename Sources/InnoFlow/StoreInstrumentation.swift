// MARK: - StoreInstrumentation.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import OSLog

/// Why a produced action was dropped before re-entering the store queue.
public enum ActionDropReason: Sendable, Equatable {
  case storeReleased
  case cancellationBoundary
  case inactiveToken
  case throttledOrDebouncedCancellation
}

/// A unified stream of store instrumentation events.
public enum StoreInstrumentationEvent<Action: Sendable>: Sendable {
  case runStarted(StoreInstrumentation<Action>.RunEvent)
  case runFinished(StoreInstrumentation<Action>.RunEvent)
  case actionEmitted(StoreInstrumentation<Action>.ActionEvent)
  case actionDropped(StoreInstrumentation<Action>.ActionDropEvent)
  case effectsCancelled(StoreInstrumentation<Action>.CancellationEvent)
}

/// Optional runtime hooks for observing effect execution without changing semantics.
public struct StoreInstrumentation<Action: Sendable>: Sendable {
  public struct RunEvent: Sendable {
    public let token: UUID
    public let cancellationID: EffectID?
    public let sequence: UInt64?

    public init(token: UUID, cancellationID: EffectID?, sequence: UInt64?) {
      self.token = token
      self.cancellationID = cancellationID
      self.sequence = sequence
    }
  }

  public struct ActionEvent: Sendable {
    public let action: Action
    public let cancellationID: EffectID?
    public let sequence: UInt64?

    public init(action: Action, cancellationID: EffectID?, sequence: UInt64?) {
      self.action = action
      self.cancellationID = cancellationID
      self.sequence = sequence
    }
  }

  public struct ActionDropEvent: Sendable {
    public let action: Action?
    public let reason: ActionDropReason
    public let cancellationID: EffectID?
    public let sequence: UInt64?

    public init(
      action: Action?,
      reason: ActionDropReason,
      cancellationID: EffectID?,
      sequence: UInt64?
    ) {
      self.action = action
      self.reason = reason
      self.cancellationID = cancellationID
      self.sequence = sequence
    }
  }

  public struct CancellationEvent: Sendable {
    public let id: EffectID?
    public let sequence: UInt64

    public init(id: EffectID?, sequence: UInt64) {
      self.id = id
      self.sequence = sequence
    }
  }

  public var didStartRun: @Sendable (RunEvent) -> Void
  public var didFinishRun: @Sendable (RunEvent) -> Void
  public var didEmitAction: @Sendable (ActionEvent) -> Void
  public var didDropAction: @Sendable (ActionDropEvent) -> Void
  public var didCancelEffects: @Sendable (CancellationEvent) -> Void

  public init(
    didStartRun: @escaping @Sendable (RunEvent) -> Void = { _ in },
    didFinishRun: @escaping @Sendable (RunEvent) -> Void = { _ in },
    didEmitAction: @escaping @Sendable (ActionEvent) -> Void = { _ in },
    didDropAction: @escaping @Sendable (ActionDropEvent) -> Void = { _ in },
    didCancelEffects: @escaping @Sendable (CancellationEvent) -> Void = { _ in }
  ) {
    self.didStartRun = didStartRun
    self.didFinishRun = didFinishRun
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

  public static func osLog(
    logger: Logger,
    includeActions: Bool = true
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

      case .actionEmitted(let actionEvent):
        let actionDescription = includeActions ? String(describing: actionEvent.action) : "<redacted>"
        logger.debug(
          "InnoFlow emitted action=\(actionDescription, privacy: .public) cancellationID=\(String(describing: actionEvent.cancellationID), privacy: .public) sequence=\(String(describing: actionEvent.sequence), privacy: .public)"
        )

      case .actionDropped(let dropEvent):
        let actionDescription = dropEvent.action.map(String.init(describing:)) ?? "<none>"
        let renderedAction = includeActions ? actionDescription : "<redacted>"
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
