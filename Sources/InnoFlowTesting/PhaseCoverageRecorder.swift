import Foundation
@_exported public import InnoFlowCore
import os

/// A declared source/target edge for one `On` declaration. Trigger IDs are
/// zero-based declaration indices, independent of action payloads and labels.
public struct PhaseCoverageTransition<Phase: Hashable & Sendable>: Hashable, Sendable {
  public let from: Phase
  public let to: Phase
  public let triggerID: Int
}

public struct PhaseCoverageReport<Phase: Hashable & Sendable>: Sendable, Equatable {
  public let covered: Set<PhaseCoverageTransition<Phase>>
  public let uncovered: Set<PhaseCoverageTransition<Phase>>
  public let hitCounts: [PhaseCoverageTransition<Phase>: Int]

  public var fraction: Double {
    let total = covered.count + uncovered.count
    return total == 0 ? 1 : Double(covered.count) / Double(total)
  }

  /// Uncovered edges are red dashed arrows. Labels are escaped; supply a
  /// unique, stable label for custom phases with identical debug descriptions.
  public func mermaid(phaseLabel: (Phase) -> String = { String(describing: $0) }) -> String {
    let transitions = covered.union(uncovered).sorted {
      if $0.triggerID != $1.triggerID { return $0.triggerID < $1.triggerID }
      return phaseLabel($0.to) < phaseLabel($1.to)
    }
    let phases = Set(transitions.flatMap { [$0.from, $0.to] }).sorted {
      phaseLabel($0) < phaseLabel($1)
    }
    let ids = Dictionary(
      uniqueKeysWithValues: phases.enumerated().map { ($0.element, "p\($0.offset)") })
    func escaped(_ text: String) -> String {
      text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\n", with: " ")
    }
    var lines = ["flowchart LR"]
    for phase in phases { lines.append("  \(ids[phase]!) [\"\(escaped(phaseLabel(phase)))\"]") }
    for edge in transitions {
      let missing = uncovered.contains(edge)
      lines.append(
        "  \(ids[edge.from]!) \(missing ? "-.->" : "-->")|\"trigger \(edge.triggerID)\(missing ? " uncovered" : "")\"| \(ids[edge.to]!)"
      )
    }
    for (index, edge) in transitions.enumerated() where uncovered.contains(edge) {
      lines.append("  linkStyle \(index) stroke:#d33,stroke-width:2px")
    }
    return lines.joined(separator: "\n")
  }
}

public enum PhaseCoverageMinimum: Sendable, Equatable {
  case all
  /// Inclusive fraction in the closed interval 0...1.
  case fraction(Double)
}

/// Thread-safe, explicitly installed observation of transitions the reducer
/// actually applied. Matchers and resolvers are never invoked by this recorder.
/// Recomputed maps from the same declaration site share an identity. Maps
/// constructed at different sites are separate, even when topology is equal.
public final class PhaseCoverageRecorder<
  State: Sendable, Action: Sendable, Phase: Hashable & Sendable
>: Sendable {
  private struct Storage: Sendable {
    var counts: [PhaseCoverageTransition<Phase>: Int] = [:]
  }
  private let identity: String
  private let keyPath: any WritableKeyPath<State, Phase> & Sendable
  private let expected: Set<PhaseCoverageTransition<Phase>>
  private let storage: OSAllocatedUnfairLock<Storage>

  public init(_ map: PhaseMap<State, Action, Phase>) {
    identity = map.observationID
    keyPath = map.phaseKeyPath
    storage = .init(initialState: Storage())
    expected = Set(
      map.rules.flatMap { rule in
        rule.transitions.flatMap { transition in
          transition.declaredTargets.compactMap { target in
            guard target != rule.sourcePhase || transition.selfTransitionPolicy == .allow else {
              return nil
            }
            return PhaseCoverageTransition(
              from: rule.sourcePhase, to: target, triggerID: transition.declarationIndex)
          }
        }
      })
  }

  public func report() -> PhaseCoverageReport<Phase> {
    let counts = storage.withLock { $0.counts }
    let covered = Set(counts.keys)
    return .init(covered: covered, uncovered: expected.subtracting(covered), hitCounts: counts)
  }

  @discardableResult
  public func assertPhaseCoverage(
    minimum: PhaseCoverageMinimum = .all,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) -> PhaseCoverageReport<Phase> {
    let result = report()
    let threshold: Double
    switch minimum {
    case .all: threshold = 1
    case .fraction(let value): threshold = value
    }
    let location = TestStoreSourceLocation(
      fileID: fileID, filePath: filePath, line: line, column: column)
    guard threshold.isFinite, (0...1).contains(threshold) else {
      testStoreAssertionFailure(
        "Phase coverage minimum must be a finite fraction in 0...1.", location: location)
      return result
    }
    if result.fraction < threshold {
      testStoreAssertionFailure(
        "Phase coverage was \(result.covered.count)/\(expected.count); required \(threshold).\n\(result.mermaid())",
        location: location
      )
    }
    return result
  }
}

extension PhaseCoverageRecorder: PhaseMapRuntimeObserver {
  package func applied<S: Sendable, A: Sendable, P: Hashable & Sendable>(
    map: PhaseMap<S, A, P>, declarationIndex: Int, from: P, to: P
  ) {
    guard identity == map.observationID, A.self == Action.self,
      S.self == State.self, P.self == Phase.self,
      let source = from as? Phase, let target = to as? Phase
    else { return }
    let edge = PhaseCoverageTransition(from: source, to: target, triggerID: declarationIndex)
    guard expected.contains(edge), keyPath == map.phaseKeyPath else { return }
    storage.withLock { value in
      value.counts[edge, default: 0] += 1
    }
  }

  package func violation(_ message: String) {}
}

/// One synchronous reduction's diagnostic buffer; no production payload log.
package final class TestStorePhaseObservation: PhaseMapRuntimeObserver, Sendable {
  private let coverage: (any PhaseMapRuntimeObserver)?
  private let messages = OSAllocatedUnfairLock(initialState: [String]())
  package init(coverage: (any PhaseMapRuntimeObserver)?) { self.coverage = coverage }
  package var violations: [String] { messages.withLock { $0 } }
  package func violation(_ message: String) { messages.withLock { $0.append(message) } }
  package func applied<S: Sendable, A: Sendable, P: Hashable & Sendable>(
    map: PhaseMap<S, A, P>, declarationIndex: Int, from: P, to: P
  ) {
    coverage?.applied(map: map, declarationIndex: declarationIndex, from: from, to: to)
  }
}

extension TestStore {
  public convenience init<Phase: Hashable & Sendable>(
    reducer: R,
    initialState: R.State,
    phaseCoverage: PhaseCoverageRecorder<R.State, R.Action, Phase>,
    clock: ManualTestClock? = nil,
    effectTimeout: Duration = .seconds(1),
    diffLineLimit: Int? = nil
  ) {
    self.init(
      reducer: reducer, initialState: initialState, clock: clock, effectTimeout: effectTimeout,
      diffLineLimit: diffLineLimit)
    phaseCoverageObserver = phaseCoverage
  }

  public convenience init<Phase: Hashable & Sendable>(
    reducer: R,
    initialState: R.State? = nil,
    phaseCoverage: PhaseCoverageRecorder<R.State, R.Action, Phase>,
    clock: ManualTestClock? = nil,
    effectTimeout: Duration = .seconds(1),
    diffLineLimit: Int? = nil
  ) where R.State: DefaultInitializable {
    self.init(
      reducer: reducer, initialState: initialState ?? R.State(), phaseCoverage: phaseCoverage,
      clock: clock, effectTimeout: effectTimeout, diffLineLimit: diffLineLimit)
  }
}
