import Foundation
@_exported public import InnoFlowCore

/// Versioned, portable PRNG. The algorithm and rejection sampling are fixed;
/// Swift's standard-library random distribution implementation is not used.
public struct SplitMix64: RandomNumberGenerator, Sendable {
  private var state: UInt64
  public init(seed: UInt64) { state = seed }
  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  package mutating func below(_ upperBound: UInt64) -> UInt64 {
    precondition(upperBound > 0)
    let threshold = (0 &- upperBound) % upperBound
    while true {
      let value = next()
      if value >= threshold { return value % upperBound }
    }
  }
}

/// An enabled interaction returned by a state-dependent generator. A weight of
/// zero disables a choice. `source` is the Swift expression for the action,
/// e.g. `.increment`, and is required for copyable scenario output.
public struct TestStoreExplorationChoice<Action: Equatable & Sendable>: Sendable, Equatable {
  package enum Operation: Sendable, Equatable {
    case send(Action)
    case receive(Action)
    case advance(Duration, sleepers: Int)
    case cancelEffects
    case finish
  }
  package let operation: Operation
  public let source: String
  public let weight: UInt64

  public static func send(_ action: Action, source: String, weight: UInt64 = 1) -> Self {
    .init(operation: .send(action), source: source, weight: weight)
  }
  public static func receive(_ action: Action, source: String, weight: UInt64 = 1) -> Self {
    .init(operation: .receive(action), source: source, weight: weight)
  }
  /// Uses the fresh store's manual clock for every replay. The explicit
  /// registration threshold prevents time advancing before an effect parks.
  public static func advance(
    by duration: Duration, onceSleepersReach count: Int, weight: UInt64 = 1
  ) -> Self {
    .init(operation: .advance(duration, sleepers: count), source: "", weight: weight)
  }
  public static func finish(weight: UInt64 = 1) -> Self {
    .init(operation: .finish, source: "", weight: weight)
  }
  public static func cancelEffects(weight: UInt64 = 1) -> Self {
    .init(operation: .cancelEffects, source: "", weight: weight)
  }

  package func sameInteraction(as other: Self) -> Bool {
    operation == other.operation && source == other.source
  }
  package func scenarioSource(clock: String) -> String {
    switch operation {
    case .send: return ".send(\(source))"
    case .receive: return ".receive(\(source))"
    case .advance(let duration, let count):
      let parts = duration.components
      return
        ".advance(\(clock), by: Duration(secondsComponent: \(parts.seconds), attosecondsComponent: \(parts.attoseconds)), onceSleepersReach: \(count))"
    case .finish: return ".finish()"
    case .cancelEffects:
      return ".init(\"cancel effects\") { store in await store.cancelAllEffects() }"
    }
  }
}

/// Deterministic generator input. Logical time is the sum of successful
/// explicit clock advances, never the wall clock or executor scheduling time.
public struct TestStoreExplorationContext<State: Sendable>: Sendable {
  public let state: State
  public let stepIndex: Int
  public let elapsedTime: Duration
}

public struct TestStoreExplorationSourceLocation: Sendable, Equatable {
  public let fileID: String
  public let filePath: String
  public let line: UInt
  public let column: UInt

  package init(_ location: TestStoreSourceLocation) {
    fileID = location.fileID.description
    filePath = location.filePath.description
    line = location.line
    column = location.column
  }
}

public struct TestStoreExplorationFailure: Sendable, Equatable {
  public enum Kind: String, Sendable { case diagnostic, generator, configuration }
  public let kind: Kind
  /// Stable comparison key used during delta debugging. For invariants this
  /// includes the invariant name, but excludes state and action payloads.
  public let signature: String
  public let message: String
  public let stepIndex: Int
  public let sourceLocation: TestStoreExplorationSourceLocation?

  package init(
    kind: Kind, signature: String, message: String, stepIndex: Int,
    sourceLocation: TestStoreExplorationSourceLocation? = nil
  ) {
    self.kind = kind
    self.signature = signature
    self.message = message
    self.stepIndex = stepIndex
    self.sourceLocation = sourceLocation
  }
}

public struct TestStoreExplorationResult<R: Reducer>: Sendable
where R.State: Equatable, R.Action: Equatable {
  public let seed: UInt64
  public let steps: [TestStoreExplorationChoice<R.Action>]
  public let minimizedSteps: [TestStoreExplorationChoice<R.Action>]
  public let failure: TestStoreExplorationFailure?
  /// True only after a fresh store reproduced the same failure signature.
  public let replayValidated: Bool
  public let wasCancelled: Bool
  /// Whether framework-owned physical activity was confirmed complete after
  /// cancellation and cleanup. Caller cancellation can end the cleanup wait
  /// early. No further replay is started when completion remains unverified.
  public let cleanupCompleted: Bool

  /// A directly runnable typed scenario. Each advance uses the destination
  /// store's clock, so the result never captures a disposed exploration store.
  public var scenario: TestStoreScenario<R> {
    .init(
      seed: seed,
      steps: minimizedSteps.map { choice in
        TestStoreScenarioStep(
          choice.scenarioSource(clock: "clock"),
          cancellationAwareOperation: { store in
            guard !Task.isCancelled else { return .cancelled }
            do { try await executeExplorationChoice(choice, on: store) } catch is CancellationError
            { return .cancelled } catch {
              store.issueReporter("Exploration replay failed: \(error)", .init())
            }
            return Task.isCancelled ? .cancelled : .completed
          })
      })
  }

  /// The caller supplies a fresh, equivalently configured store and its clock.
  /// Action expressions come from the generator's explicit `source` strings.
  public func scenarioSource(
    reducerType: String = String(describing: R.self),
    store: String = "store",
    clock: String = "clock"
  ) -> String {
    let body = minimizedSteps.map { "    \($0.scenarioSource(clock: clock))" }.joined(
      separator: ",\n")
    return """
      \(store).exhaustivity = .off
      let scenario = TestStoreScenario<\(reducerType)>(seed: \(seed), steps: [
      \(body)
      ])
      await scenario.run(on: \(store))
      """
  }
}

/// Seeded, state-aware exploration with replay-validated delta debugging.
///
/// The factory must create fresh state, clock, dependencies and invariants for
/// every run. Determinism requires deterministic reducers/dependencies and
/// explicit receive/clock barriers for asynchronous work. Seed alone cannot
/// make external networking or racing effects deterministic. The generator is
/// pure and returns enabled choices in stable order; it is called again to
/// validate every retained step during minimization. Invalid subsequences are
/// rejected, rather than mistaking a missing prerequisite for the original bug.
@MainActor
public struct TestStoreExplorer<R: Reducer> where R.State: Equatable, R.Action: Equatable {
  public typealias Choice = TestStoreExplorationChoice<R.Action>
  public let seed: UInt64
  private let makeStore: @MainActor () -> TestStore<R>
  private let choices: @MainActor (TestStoreExplorationContext<R.State>) throws -> [Choice]

  public init(
    seed: UInt64,
    makeStore: @escaping @MainActor () -> TestStore<R>,
    choices: @escaping @MainActor (R.State) throws -> [Choice]
  ) {
    self.seed = seed
    self.makeStore = makeStore
    self.choices = { try choices($0.state) }
  }

  /// Context-aware form for clock/state generators. Include receive barriers
  /// after advancing time when an effect's result controls the next choice.
  public init(
    seed: UInt64,
    makeStore: @escaping @MainActor () -> TestStore<R>,
    generator: @escaping @MainActor (TestStoreExplorationContext<R.State>) throws -> [Choice]
  ) {
    self.seed = seed
    self.makeStore = makeStore
    self.choices = generator
  }

  public func run(maxSteps: Int = 1_000, minimize: Bool = true) async -> TestStoreExplorationResult<
    R
  > {
    let original = await attempt(replaying: nil, maxSteps: max(0, maxSteps))
    var best = original.steps
    var validated = false
    var cleanupCompleted = original.cleanupCompleted
    var replayBlocked = !cleanupCompleted
    if let failure = original.failure, failure.kind == .diagnostic, !original.cancelled,
      !original.invalid, !replayBlocked,
      !Task.isCancelled
    {
      let confirmation = await attempt(replaying: best, maxSteps: best.count)
      cleanupCompleted = cleanupCompleted && confirmation.cleanupCompleted
      replayBlocked = !cleanupCompleted
      validated = confirmation.matches(failure)
      if minimize, validated {
        var granularity = 2
        while best.count >= 2, !Task.isCancelled, !replayBlocked {
          let chunk = (best.count + granularity - 1) / granularity
          var reduced = false
          for start in stride(from: 0, to: best.count, by: chunk) {
            let end = min(best.count, start + chunk)
            let candidate = Array(best[..<start]) + Array(best[end...])
            let result = await attempt(replaying: candidate, maxSteps: candidate.count)
            if !result.cleanupCompleted {
              cleanupCompleted = false
              replayBlocked = true
              break
            }
            if result.matches(failure) {
              best = candidate
              granularity = max(2, granularity - 1)
              reduced = true
              break
            }
            if Task.isCancelled { break }
          }
          if !reduced {
            if granularity >= best.count { break }
            granularity = min(best.count, granularity * 2)
          }
        }
        if !Task.isCancelled, !replayBlocked {
          // Do not advertise a minimized reproduction on an unstable replay.
          let finalCheck = await attempt(replaying: best, maxSteps: best.count)
          cleanupCompleted = cleanupCompleted && finalCheck.cleanupCompleted
          replayBlocked = !cleanupCompleted
          validated = finalCheck.matches(failure)
          if !validated { best = original.steps }
        }
      }
    }
    if replayBlocked {
      best = original.steps
      validated = false
    }
    return .init(
      seed: seed, steps: original.steps, minimizedSteps: best, failure: original.failure,
      replayValidated: validated, wasCancelled: original.cancelled || Task.isCancelled,
      cleanupCompleted: cleanupCompleted)
  }

  private struct Attempt {
    var steps: [Choice] = []
    var failure: TestStoreExplorationFailure?
    var invalid = false
    var cancelled = false
    var cleanupCompleted = false
    func matches(_ target: TestStoreExplorationFailure) -> Bool {
      !invalid && !cancelled && cleanupCompleted && failure?.kind == target.kind
        && failure?.signature == target.signature
        && failure?.sourceLocation == target.sourceLocation
    }
  }

  private func attempt(replaying replay: [Choice]?, maxSteps: Int) async -> Attempt {
    let store = makeStore()
    store.exhaustivity = .off
    var result = Attempt()
    var diagnostic: String?
    var diagnosticLocation: TestStoreExplorationSourceLocation?
    store.issueReporter = { message, location in
      if diagnostic == nil {
        diagnostic = message
        diagnosticLocation = .init(location)
      }
    }
    store.warningReporter = { _, _ in }
    var random = SplitMix64(seed: seed)
    var elapsedTime: Duration = .zero
    for index in 0..<maxSteps {
      if Task.isCancelled {
        result.cancelled = true
        break
      }
      let available: [Choice]
      do {
        available = try choices(
          .init(state: store.state, stepIndex: index, elapsedTime: elapsedTime)
        ).filter { $0.weight > 0 }
      } catch {
        result.failure = .init(
          kind: .generator, signature: String(reflecting: type(of: error)),
          message: String(describing: error), stepIndex: index)
        break
      }
      let choice: Choice
      if let replay {
        choice = replay[index]
        guard available.contains(where: { $0.sameInteraction(as: choice) }) else {
          result.invalid = true
          break
        }
      } else {
        guard !available.isEmpty else { break }
        var total: UInt64 = 0
        var overflow = false
        for item in available {
          let sum = total.addingReportingOverflow(item.weight)
          total = sum.partialValue
          overflow = overflow || sum.overflow
        }
        guard !overflow, total > 0 else {
          result.failure = .init(
            kind: .configuration, signature: "weight overflow",
            message: "Exploration choice weights overflow UInt64.", stepIndex: index)
          break
        }
        var ticket = random.below(total)
        var selected = available[0]
        for item in available {
          if ticket < item.weight {
            selected = item
            break
          }
          ticket -= item.weight
        }
        choice = selected
      }
      result.steps.append(choice)
      do {
        try await executeExplorationChoice(choice, on: store)
        if case .advance(let duration, _) = choice.operation { elapsedTime += duration }
      } catch is CancellationError {
        result.cancelled = true
        break
      } catch let error as ExplorationInteractionError {
        if let message = diagnostic {
          result.failure = .init(
            kind: .diagnostic, signature: explorationFailureSignature(message),
            message: message, stepIndex: index, sourceLocation: diagnosticLocation)
        } else {
          result.failure = .init(
            kind: .configuration, signature: "exploration precondition: \(error)",
            message: "Exploration clock configuration or registration failed: \(error)",
            stepIndex: index)
        }
        result.invalid = true
        break
      } catch {
        diagnostic = diagnostic ?? "Exploration interaction failed: \(error)"
      }
      if let message = diagnostic {
        result.failure = .init(
          kind: .diagnostic, signature: explorationFailureSignature(message),
          message: message, stepIndex: index, sourceLocation: diagnosticLocation)
        break
      }
    }
    // A new replay must not accumulate uncooperative work from older attempts.
    // Failure to physically join is a configuration/cleanup boundary, never a
    // fabricated reducer reproduction. Keep any original diagnostic intact.
    store.issueReporter = { _, _ in }
    await store.cancelAllEffects()
    _ = await store.finishResult(timeout: store.effectTimeout)
    // A cancelled caller makes finishResult return .cancelled even for an
    // already idle store. The physical activity ledger is the authority;
    // cancellation acceptance alone cannot prove completion.
    result.cleanupCompleted = store.finishActivity.snapshot.activeCount == 0
    if !result.cleanupCompleted {
      result.invalid = true
      if result.failure == nil && !Task.isCancelled {
        result.failure = .init(
          kind: .configuration, signature: "incomplete physical cleanup",
          message:
            "Exploration stopped: cancelled work did not physically finish within the cleanup budget. No further replay was started.",
          stepIndex: result.steps.count)
      }
    }
    result.cancelled = result.cancelled || Task.isCancelled
    return result
  }
}

private enum ExplorationInteractionError: Error {
  case missingManualClock
  case invalidClockAdvance
  case sleeperRegistrationTimedOut
}

@MainActor
private func executeExplorationChoice<R: Reducer>(
  _ choice: TestStoreExplorationChoice<R.Action>, on store: TestStore<R>
) async throws where R.State: Equatable, R.Action: Equatable {
  try Task.checkCancellation()
  switch choice.operation {
  case .send(let action): await store.send(action)
  case .receive(let action): await store.receive(action)
  case .cancelEffects: await store.cancelAllEffects()
  case .finish: await store.finish()
  case .advance(let duration, let sleepers):
    guard duration >= .zero, sleepers >= 0 else {
      throw ExplorationInteractionError.invalidClockAdvance
    }
    guard let clock = store.manualClock else {
      throw ExplorationInteractionError.missingManualClock
    }
    // An already satisfied registration threshold must win even with a
    // zero budget. The timeout bounds only registration, never the finite
    // actor/yield work that advances logical time after readiness is known.
    if await clock.sleeperCount < sleepers {
      let timeout = store.effectTimeout
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await clock.waitForSleepers(atLeast: sleepers) }
        group.addTask {
          try await ContinuousClock().sleep(for: timeout)
          throw ExplorationInteractionError.sleeperRegistrationTimedOut
        }
        defer { group.cancelAll() }
        try await group.next()
      }
    }
    try Task.checkCancellation()
    await clock.advance(by: duration)
  }
  try Task.checkCancellation()
}

private func explorationFailureSignature(_ message: String) -> String {
  let lines = message.split(separator: "\n").map(String.init)
  let identity = lines.filter {
    $0.hasPrefix("Error type:") || $0.hasPrefix("Error:")
      || $0.hasPrefix("PhaseMap declaration:") || $0.hasPrefix("phaseKeyPath:")
  }
  return ([lines.first ?? ""] + identity).joined(separator: "\n")
}
