// Test-only shared declarations. Production products do not depend on this target.
import Foundation
package import InnoFlowCore

func effectOperationSignature<Action: Sendable, Output: Sendable>(
  _ effect: ReducerEffect<Action, Output>
) -> String {
  switch effect.operation {
  case .none:
    return "none"

  case .send(let action):
    return "send(\(String(describing: action)))"

  case .output(let output):
    return "output(\(String(describing: output)))"

  case .run(let priority, _):
    return "run(priority:\(String(describing: priority)))"

  case .scheduledRun(let id, let policy, let priority, _, _):
    return
      "scheduledRun(id:\(id.description),policy:\(String(describing: policy)),priority:\(String(describing: priority)))"

  case .merge(let children):
    return "merge(\(children.map(effectOperationSignature).joined(separator: ",")))"

  case .concatenate(let children):
    return "concatenate(\(children.map(effectOperationSignature).joined(separator: ",")))"

  case .cancel(let id):
    return "cancel(\(id.description))"

  case .cancellable(let nested, let id, let cancelInFlight):
    return
      "cancellable(id:\(id.description),cancelInFlight:\(cancelInFlight),nested:\(effectOperationSignature(nested)))"

  case .debounce(let nested, let id, let interval):
    return
      "debounce(id:\(id.description),interval:\(interval),nested:\(effectOperationSignature(nested)))"

  case .throttle(let nested, let id, let interval, let leading, let trailing):
    return
      "throttle(id:\(id.description),interval:\(interval),leading:\(leading),trailing:\(trailing),nested:\(effectOperationSignature(nested)))"

  case .animation(let nested, let animation):
    return "animation(\(String(describing: animation)),nested:\(effectOperationSignature(nested)))"

  case .lazyMap(let lazy):
    return effectOperationSignature(lazy.materialize())

  case .optionalChild(_, let before, let after, let child, let parent):
    return
      "optionalChild(before:\(String(describing: before)),after:\(String(describing: after)),child:\(effectOperationSignature(child)),parent:\(effectOperationSignature(parent)))"

  case .lifetimeScope(_, let nested):
    return "lifetimeScope(nested:\(effectOperationSignature(nested)))"

  case .owned(_, let nested):
    return "owned(nested:\(effectOperationSignature(nested)))"

  case .diagnosticDrop(let action, let reason):
    let actionDescription = String(describing: action)
    let reasonDescription = String(describing: reason)
    return "diagnosticDrop(action:\(actionDescription),reason:\(reasonDescription))"
  }
}

func normalizedConcatenateSignature<Action: Sendable, Output: Sendable>(
  _ effect: ReducerEffect<Action, Output>
)
  -> String
{
  switch effect.operation {
  case .concatenate(let children):
    return
      children
      .flatMap(flattenConcatenateChildren)
      .map(effectOperationSignature)
      .joined(separator: " -> ")

  default:
    return effectOperationSignature(effect)
  }
}

func flattenConcatenateChildren<Action: Sendable, Output: Sendable>(
  _ effect: ReducerEffect<Action, Output>
)
  -> [ReducerEffect<Action, Output>]
{
  switch effect.operation {
  case .concatenate(let children):
    return children.flatMap(flattenConcatenateChildren)

  default:
    return [effect]
  }
}

package func settleTimingScenarioWork() async {
  // `Store.send` schedules non-`.send` effects onto a separate Task. For the
  // randomized debounce/throttle property tests, some in-window updates only
  // mutate internal pending state and do not immediately change user-visible
  // state or sleeper counts. A pure `Task.yield()` loop can therefore advance
  // the manual clock before the walker Task has actually applied the pending
  // replacement under release optimization. Add a tiny wall-clock handoff so
  // the queued Task gets a real executor turn before the scenario continues.
  await drainAsyncWork(iterations: 64)
  try? await Task.sleep(for: .milliseconds(1))
  await drainAsyncWork(iterations: 64)
}

@MainActor
package func waitForEmissionCount<R: Reducer>(
  _ store: Store<R>,
  emitted: KeyPath<R.State, [Int]>,
  minimumCount: Int,
  timeout: Duration = .seconds(2)
) async -> Bool {
  guard minimumCount > 0 else { return true }

  return await waitUntil(
    timeout: timeout,
    pollInterval: .milliseconds(1)
  ) {
    store.state[keyPath: emitted].count >= minimumCount
  }
}

func drainAsyncWork(iterations: Int = 128) async {
  for _ in 0..<iterations {
    await Task.yield()
  }
}

@MainActor
@discardableResult
func waitUntil(
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(20),
  condition: @escaping @MainActor () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if condition() {
      return true
    }
    try? await Task.sleep(for: pollInterval)
  }

  return condition()
}

func waitUntilAsync(
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(20),
  settleIterations: Int = 16,
  condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if await condition() {
      return true
    }
    await drainAsyncWork(iterations: settleIterations)
    try? await Task.sleep(for: pollInterval)
  }

  return await condition()
}

@MainActor
func waitForProjectionObserverStats<R: Reducer>(
  _ store: Store<R>,
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(10),
  condition: @escaping @MainActor (ProjectionObserverRegistryStats) -> Bool
) async {
  await waitUntil(timeout: timeout, pollInterval: pollInterval) {
    condition(store.projectionObserverStats)
  }
}

@MainActor
func waitForProjectionRefreshPass<R: Reducer>(
  _ store: Store<R>,
  after previousStats: ProjectionObserverRegistryStats,
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(10)
) async {
  await waitForProjectionObserverStats(
    store,
    timeout: timeout,
    pollInterval: pollInterval
  ) { stats in
    stats.refreshPassCount > previousStats.refreshPassCount
  }
}

var isHeavyStressEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_HEAVY_STRESS"] == "1"
}

var isPerformanceBenchmarkEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_PERF_BENCHMARKS"] == "1"
}

package struct SeededGenerator {
  private var state: UInt64

  package init(seed: UInt64) {
    self.state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
  }

  package mutating func next() -> UInt64 {
    state = 2_862_933_555_777_941_757 &* state &+ 3_037_000_493
    return state
  }

  package mutating func nextInt(upperBound: Int) -> Int {
    precondition(upperBound > 0)
    return Int(next() % UInt64(upperBound))
  }
}
