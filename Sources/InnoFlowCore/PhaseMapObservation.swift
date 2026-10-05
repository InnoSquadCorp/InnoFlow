// Package-only bridge: Core has no dependency on testing or a global recorder.
package protocol PhaseMapRuntimeObserver: Sendable {
  func applied<State: Sendable, Action: Sendable, Phase: Hashable & Sendable>(
    map: PhaseMap<State, Action, Phase>, declarationIndex: Int, from: Phase, to: Phase
  )
  func violation(_ message: String)
}

package enum PhaseMapRuntimeObservation {
  /// Installed only around one synchronous TestStore reduction. Child tasks
  /// are never created in this scope and cannot retain a testing observer.
  @TaskLocal package static var observer: (any PhaseMapRuntimeObserver)?

  package static func violation(_ message: @autoclosure () -> String, declaration: String) {
    if let observer {
      observer.violation(message() + "\nPhaseMap declaration: " + declaration)
    } else {
      assertionFailure(message())
    }
  }
}
