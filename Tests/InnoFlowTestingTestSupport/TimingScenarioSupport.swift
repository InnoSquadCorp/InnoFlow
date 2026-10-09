// Test-only shared declarations. Production products do not depend on this target.
import Foundation
import InnoFlowCore
import InnoFlowCoreTestSupport
import InnoFlowTesting
import Testing

enum TimingScenarioStep: Sendable {
  case trigger(Int)
  case advance(Int)
}

struct TimingScenarioExpectation: Equatable, Sendable {
  var outputs: [Int]
  var emissionCountsAfterSteps: [Int]
}

func makeTimingScenario(
  seed: UInt64,
  maxSteps: Int = 100
) -> [TimingScenarioStep] {
  var rng = SeededGenerator(seed: seed)
  let count = rng.nextInt(upperBound: maxSteps - 20) + 20
  var steps: [TimingScenarioStep] = []

  for index in 0..<count {
    if index == 0 || rng.nextInt(upperBound: 100) < 60 {
      steps.append(.trigger(rng.nextInt(upperBound: 10_000)))
    } else {
      steps.append(.advance(rng.nextInt(upperBound: 120) + 1))
    }
  }

  steps.append(.advance(200))
  return steps
}

func expectedDebounceOutputs(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int
) -> [Int] {
  expectedDebounceTimeline(
    for: steps,
    intervalMilliseconds: intervalMilliseconds
  ).outputs
}

func expectedDebounceTimeline(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int
) -> TimingScenarioExpectation {
  var time = 0
  var pending: (value: Int, due: Int)?
  var emitted: [Int] = []
  var countsAfterSteps: [Int] = []

  for step in steps {
    switch step {
    case .trigger(let value):
      pending = (value, time + intervalMilliseconds)

    case .advance(let delta):
      time += delta
      if let scheduled = pending, scheduled.due <= time {
        emitted.append(scheduled.value)
        pending = nil
      }
    }

    countsAfterSteps.append(emitted.count)
  }

  return .init(
    outputs: emitted,
    emissionCountsAfterSteps: countsAfterSteps
  )
}

func expectedThrottleOutputs(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int,
  leading: Bool,
  trailing: Bool
) -> [Int] {
  expectedThrottleTimeline(
    for: steps,
    intervalMilliseconds: intervalMilliseconds,
    leading: leading,
    trailing: trailing
  ).outputs
}

func expectedThrottleTimeline(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int,
  leading: Bool,
  trailing: Bool
) -> TimingScenarioExpectation {
  precondition(leading || trailing)

  var time = 0
  var windowEnd: Int?
  var pending: Int?
  var emitted: [Int] = []
  var countsAfterSteps: [Int] = []

  for step in steps {
    switch step {
    case .trigger(let value):
      if let activeWindowEnd = windowEnd, time < activeWindowEnd {
        if trailing {
          pending = value
        }
        countsAfterSteps.append(emitted.count)
        continue
      }

      windowEnd = time + intervalMilliseconds
      pending = nil

      if leading {
        emitted.append(value)
      } else if trailing {
        pending = value
      }

    case .advance(let delta):
      time += delta
      if let activeWindowEnd = windowEnd, activeWindowEnd <= time {
        if trailing, let pending {
          emitted.append(pending)
        }
        windowEnd = nil
        pending = nil
      }
    }

    countsAfterSteps.append(emitted.count)
  }

  return .init(
    outputs: emitted,
    emissionCountsAfterSteps: countsAfterSteps
  )
}

@MainActor
func runTimingScenario<R: Reducer>(
  reducer: R,
  steps: [TimingScenarioStep],
  trigger: @escaping (Int) -> R.Action,
  emitted: KeyPath<R.State, [Int]>,
  expectedCount: Int,
  expectedCountAfterEachStep: [Int]? = nil,
  awaitSleepRegistrationAfterTrigger: Bool = false,
  awaitNowReadAfterTrigger: Bool = false
) async throws -> [Int]
where
  R.State: Equatable & Sendable & DefaultInitializable,
  R.Action: Sendable
{
  if let expectedCountAfterEachStep {
    precondition(expectedCountAfterEachStep.count == steps.count)
  }

  let clock = ManualTestClock()
  let store = Store(
    reducer: reducer,
    initialState: .init(),
    clock: .manual(clock)
  )

  for (index, step) in steps.enumerated() {
    switch step {
    case .trigger(let value):
      if awaitSleepRegistrationAfterTrigger {
        let previousRegistrationCount = await clock.sleepRegistrationCount
        store.send(trigger(value))
        // Deterministic: resumes on the registration event itself instead of
        // polling with a wall-clock timeout.
        try await clock.waitForSleepRegistrations(toReach: previousRegistrationCount + 1)
      } else if awaitNowReadAfterTrigger {
        let previousNowReadCount = await clock.nowReadCount
        store.send(trigger(value))
        // Active-window throttle updates reuse the existing sleeper. Wait for
        // their scheduling-time read so manual time cannot move first under a
        // slow executor or sanitizer build.
        try await clock.waitForNowReads(toReach: previousNowReadCount + 1)
        await settleTimingScenarioWork()
      } else {
        store.send(trigger(value))
        await settleTimingScenarioWork()
      }

    case .advance(let milliseconds):
      await settleTimingScenarioWork()
      await clock.advance(by: .milliseconds(milliseconds))
      await settleTimingScenarioWork()
    }

    if let expectedCountAfterEachStep {
      try #require(
        await waitForEmissionCount(
          store,
          emitted: emitted,
          minimumCount: expectedCountAfterEachStep[index]
        ),
        "Timed out waiting for the expected emission count after timing step \(index)"
      )
    }
  }

  try #require(
    await waitForEmissionCount(
      store,
      emitted: emitted,
      minimumCount: expectedCount
    ),
    "Timed out waiting for the final expected emission count"
  )

  return store.state[keyPath: emitted]
}
