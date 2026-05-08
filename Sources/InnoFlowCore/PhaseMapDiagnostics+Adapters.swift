// MARK: - PhaseMapDiagnostics+Adapters.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import OSLog
public import os

extension PhaseMapDiagnostics {
  /// A diagnostics reporter that forwards every violation to `receive`. Useful
  /// for vendor-specific observability backends or test probes.
  ///
  /// The closure runs synchronously inside the reducer's post-reduce phase,
  /// so keep it lightweight or hand the violation off to a background queue
  /// before doing expensive work.
  public static func sink(
    _ receive: @escaping @Sendable (PhaseMapViolation<Action, Phase>) -> Void
  ) -> Self {
    .init(report: receive)
  }

  /// Fans every violation out to multiple diagnostics reporters in declaration
  /// order. Use this to combine `.osLog`, `.signpost`, and a custom `.sink`
  /// that ships counters to a metrics backend.
  public static func combined(_ diagnostics: Self...) -> Self {
    .init { violation in
      for diagnostic in diagnostics {
        diagnostic.report(violation)
      }
    }
  }

  /// Logs every violation through the supplied `Logger`.
  ///
  /// Action payloads are redacted by default. Set `includeActionPayload` to
  /// `true` only in local debugging contexts where public Console visibility is
  /// intentional. Phase labels are emitted publicly because they are expected to
  /// be operational enum names rather than user payloads.
  public static func osLog(
    logger: Logger,
    includeActionPayload: Bool = false
  ) -> Self {
    .sink { violation in
      switch violation {
      case .directPhaseMutation(let action, let previous, let postReduce):
        let renderedAction = includeActionPayload ? String(describing: action) : "<redacted>"
        logger.error(
          "InnoFlow phaseMap direct mutation action=\(renderedAction, privacy: .public) previous=\(String(describing: previous), privacy: .public) postReduce=\(String(describing: postReduce), privacy: .public)"
        )

      case .undeclaredTarget(let action, let source, let target, let declared):
        let renderedAction = includeActionPayload ? String(describing: action) : "<redacted>"
        logger.error(
          "InnoFlow phaseMap undeclared target action=\(renderedAction, privacy: .public) sourcePhase=\(String(describing: source), privacy: .public) target=\(String(describing: target), privacy: .public) declaredTargets=\(String(describing: declared), privacy: .public)"
        )
      }
    }
  }

  /// Surfaces every violation as an Instruments signpost event so phase-map
  /// violations show up alongside store-instrumentation signposts on the same
  /// timeline.
  ///
  /// Action payloads are redacted by default — the same reason as in
  /// `StoreInstrumentation.signpost(...)`: signpost arguments can be captured
  /// by traces shipped off-device, and `String(describing:)` may surface user
  /// data that does not belong in those captures.
  public static func signpost(
    signposter: OSSignposter,
    name: StaticString = "InnoFlow.phaseMap",
    includeActionPayload: Bool = false
  ) -> Self {
    .sink { violation in
      switch violation {
      case .directPhaseMutation(let action, let previous, let postReduce):
        let renderedAction = includeActionPayload ? String(describing: action) : "<redacted>"
        signposter.emitEvent(
          name,
          "directPhaseMutation action=\(renderedAction) previous=\(String(describing: previous)) postReduce=\(String(describing: postReduce))"
        )

      case .undeclaredTarget(let action, let source, let target, let declared):
        let renderedAction = includeActionPayload ? String(describing: action) : "<redacted>"
        signposter.emitEvent(
          name,
          "undeclaredTarget action=\(renderedAction) sourcePhase=\(String(describing: source)) target=\(String(describing: target)) declaredTargets=\(String(describing: declared))"
        )
      }
    }
  }
}
