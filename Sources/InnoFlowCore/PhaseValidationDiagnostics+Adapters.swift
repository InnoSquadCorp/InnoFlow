// MARK: - PhaseValidationDiagnostics+Adapters.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import OSLog
public import os

extension PhaseValidationDiagnostics {
  /// A diagnostics reporter that forwards every violation to `receive`. Useful
  /// for vendor-specific observability backends or test probes.
  public static func sink(
    _ receive: @escaping @Sendable (PhaseValidationViolation<Action, Phase>) -> Void
  ) -> Self {
    .init(report: receive)
  }

  /// Fans every violation out to multiple diagnostics reporters in declaration
  /// order. Empty or all-`.disabled` compositions preserve `.disabled`
  /// semantics, including the legacy debug assertion path.
  public static func combined(_ diagnostics: Self...) -> Self {
    let reports = diagnostics.compactMap(\.report)
    guard !reports.isEmpty else {
      return .disabled
    }

    return .init { violation in
      for report in reports {
        report(violation)
      }
    }
  }

  /// Logs every validation violation through the supplied `Logger`.
  ///
  /// Action payloads and phase labels are redacted by default. Set
  /// `includeActionPayload` and `includePhaseInfo` to `true` only in local
  /// debugging contexts where public Console visibility is intentional.
  public static func osLog(
    logger: Logger,
    includeActionPayload: Bool = false,
    includePhaseInfo: Bool = false
  ) -> Self {
    .sink { violation in
      switch violation {
      case .undeclaredTransition(let action, let previous, let next, let allowed):
        let renderedAction = includeActionPayload ? String(describing: action) : "<redacted>"
        if includePhaseInfo {
          let renderedPrevious = String(describing: previous)
          let renderedNext = String(describing: next)
          let renderedAllowed = String(describing: allowed)
          logger.error(
            "InnoFlow phase validation undeclared transition action=\(renderedAction, privacy: .public) previous=\(renderedPrevious, privacy: .public) next=\(renderedNext, privacy: .public) allowedNextPhases=\(renderedAllowed, privacy: .public)"
          )
        } else {
          logger.error(
            "InnoFlow phase validation undeclared transition action=\(renderedAction, privacy: .public) previous=\("<redacted>", privacy: .public) next=\("<redacted>", privacy: .public) allowedNextPhases=\("<redacted>", privacy: .public)"
          )
        }
      }
    }
  }

  /// Surfaces every validation violation as an Instruments signpost event.
  ///
  /// Action payloads and phase labels are redacted by default because traces can
  /// leave the device. Opt in with `includeActionPayload: true` and
  /// `includePhaseInfo: true` only when payload visibility is intentional.
  public static func signpost(
    signposter: OSSignposter,
    name: StaticString = "InnoFlow.phaseValidation",
    includeActionPayload: Bool = false,
    includePhaseInfo: Bool = false
  ) -> Self {
    .sink { violation in
      switch violation {
      case .undeclaredTransition(let action, let previous, let next, let allowed):
        let renderedAction = includeActionPayload ? String(describing: action) : "<redacted>"
        let renderedPrevious = includePhaseInfo ? String(describing: previous) : "<redacted>"
        let renderedNext = includePhaseInfo ? String(describing: next) : "<redacted>"
        let renderedAllowed = includePhaseInfo ? String(describing: allowed) : "<redacted>"
        signposter.emitEvent(
          name,
          id: .exclusive,
          "undeclaredTransition action=\(renderedAction) previous=\(renderedPrevious) next=\(renderedNext) allowedNextPhases=\(renderedAllowed)"
        )
      }
    }
  }
}
