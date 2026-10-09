import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing
import os

@Suite("Observed phase coverage and seeded exploration")
@MainActor
struct PhaseExplorationConsistencyTests {
  @Test("coverage distinguishes accepted self transition, guarded nil and duplicate topology")
  func actualTransitionCoverage() async {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let map = CoverageFixture.map(calls: calls)
    let recorder = PhaseCoverageRecorder(map)
    let store = TestStore(reducer: CoverageFixture(map: map), phaseCoverage: recorder)
    store.exhaustivity = .off
    await store.send(.guarded, through: map)
    #expect(recorder.report().covered.isEmpty)
    #expect(calls.withLock { $0 } == 1)
    await store.send(.tick, through: map)
    #expect(recorder.report().covered.count == 1)
    #expect(recorder.report().covered.first?.from == .idle)
    #expect(recorder.report().covered.first?.to == .idle)
    await store.send(.load, through: map)
    await store.receive(.loaded, through: map)
    let report = recorder.report()
    #expect(report.covered.count == 3)
    #expect(report.uncovered.count == 3)
    #expect(report.uncovered.map(\.triggerID).sorted() == [1, 4, 5])
    #expect(report.mermaid().contains("trigger 4 uncovered"))
    #expect(report.mermaid() == report.mermaid())
    let matchedIssues = OSAllocatedUnfairLock(initialState: 0)
    let expectedMessage = "Phase coverage was 3/6; required 1.0.\n\(report.mermaid())"
    withKnownIssue("Only three of six declared edges were exercised") {
      recorder.assertPhaseCoverage(
        minimum: .all, fileID: "CoverageTests/Explicit.swift",
        filePath: "/fixtures/PhaseCoverage.swift", line: 73, column: 9)
    } matching: { issue in
      guard let error = issue.error,
        String(describing: error) == expectedMessage,
        issue.sourceLocation
          == SourceLocation(
            fileID: "CoverageTests/Explicit.swift", filePath: "/fixtures/PhaseCoverage.swift",
            line: 73, column: 9)
      else { return false }
      return matchedIssues.withLock { count in
        count += 1
        return count == 1
      }
    }
    #expect(matchedIssues.withLock { $0 } == 1)
    await store.finish()
  }

  @Test("parallel stores aggregate exact counts while independent map sites do not mix")
  func sharedRecorder() async {
    let map = CoverageFixture.map(calls: .init(initialState: 0))
    let recorder = PhaseCoverageRecorder(map)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<32 {
        group.addTask { await recordCoverageTick(recorder) }
      }
    }
    #expect(recorder.report().hitCounts.values.reduce(0, +) == 32)
    let otherMap = PhaseMap<
      CoverageFixture.State, CoverageFixture.Action, CoverageFixture.State.Phase
    >(\.phase) {
      From(.idle) { On(.tick, to: .idle, selfTransitionPolicy: .allow) }
    }
    let other = TestStore(reducer: CoverageFixture(map: otherMap), phaseCoverage: recorder)
    await other.send(.tick)
    await other.finish()
    #expect(recorder.report().hitCounts.values.reduce(0, +) == 32)
  }

  @Test("illegal PhaseMap mutation becomes a TestStore diagnostic without trapping")
  func phaseViolationsAreSearchable() async {
    let explorer = TestStoreExplorer(
      seed: 7,
      makeStore: {
        TestStore(reducer: CoverageFixture(map: CoverageFixture.map(calls: .init(initialState: 0))))
      }, choices: { _ in [.send(.illegal, source: ".illegal")] })
    let result = await explorer.run()
    #expect(result.failure?.message.contains("Base reducer must not mutate phase directly") == true)
    #expect(result.steps.count == 1)
    #expect(result.replayValidated)
  }

  @Test("undeclared targets and forbidden self transitions report without inventing coverage")
  func rejectedTransitions() async {
    let map = PhaseMap<CoverageFixture.State, CoverageFixture.Action, CoverageFixture.State.Phase>(
      \.phase
    ) {
      From(.idle) {
        On(.guarded, targets: [.loading]) { _ in .failed }
        On(.tick, to: .idle, selfTransitionPolicy: .forbid)
      }
    }
    let recorder = PhaseCoverageRecorder(map)
    let store = TestStore(reducer: CoverageFixture(map: map), phaseCoverage: recorder)
    var messages: [String] = []
    store.issueReporter = { message, _ in messages.append(message) }
    await store.send(.guarded)
    await store.send(.tick)
    #expect(messages.count == 2)
    #expect(messages[0].contains("outside the declared targets"))
    #expect(messages[1].contains("selfTransitionPolicy was `.forbid`"))
    #expect(store.state.phase == .idle)
    #expect(recorder.report().covered.isEmpty)
    #expect(recorder.report().uncovered.count == 1)
    await store.finish()
  }

  @Test("SplitMix64 uses fixed reference vectors")
  func randomVectors() {
    var random = SplitMix64(seed: 0)
    #expect(random.next() == 0xe220_a839_7b1d_cdaf)
    #expect(random.next() == 0x6e78_9e6a_a1b9_65f4)
    #expect(random.next() == 0x06c4_5d18_8009_454f)
  }

  @Test("same seed discovers invariant bug within budget and minimizes with valid prerequisites")
  func seededReplayAndMinimization() async {
    func explorer() -> TestStoreExplorer<BugFixture> {
      .init(
        seed: 0x600,
        makeStore: {
          let store = TestStore(reducer: BugFixture())
          store.addInvariant("count nonnegative") { $0.count >= 0 }
          return store
        },
        choices: { state in
          var choices: [TestStoreExplorationChoice<BugFixture.Action>] = [
            .send(.noise, source: ".noise", weight: 5)
          ]
          if !state.armed {
            choices.append(.send(.arm, source: ".arm", weight: 2))
          } else {
            choices.append(.send(.breakCount, source: ".breakCount", weight: 2))
          }
          return choices
        })
    }
    let first = await explorer().run()
    let second = await explorer().run()
    #expect(first.steps == second.steps)
    #expect(first.failure?.signature == "TestStore invariant failed: count nonnegative")
    #expect(first.steps.count <= 1_000)
    #expect(first.minimizedSteps.map(\.source) == [".arm", ".breakCount"])
    #expect(first.replayValidated)
    #expect(first.scenarioSource().contains("seed: 1536"))
    let replay = TestStore(reducer: BugFixture())
    replay.exhaustivity = .off
    replay.addInvariant("count nonnegative") { $0.count >= 0 }
    var messages: [String] = []
    replay.issueReporter = { text, _ in messages.append(text) }
    _ = await first.scenario.run(on: replay)
    #expect(replay.state.count == -1)
    #expect(messages.count == 1)
    await replay.finish()
  }

  @Test("manual time and explicit receive replay on fresh clocks")
  func clockProgression() async {
    func explorer() -> TestStoreExplorer<ClockFixture> {
      .init(
        seed: 123,
        makeStore: {
          TestStore(reducer: ClockFixture(), clock: ManualTestClock())
        },
        generator: { context in
          switch context.state.stage {
          case 0: return [.send(.start, source: ".start")]
          case 1 where context.elapsedTime < .seconds(1):
            return [.advance(by: .seconds(1), onceSleepersReach: 1)]
          case 1: return [.receive(.ready, source: ".ready")]
          default: return []
          }
        })
    }
    let first = await explorer().run()
    let second = await explorer().run()
    #expect(first.steps == second.steps)
    #expect(first.failure == nil)
    let clock = ManualTestClock()
    let store = TestStore(reducer: ClockFixture(), clock: clock)
    store.exhaustivity = .off
    _ = await first.scenario.run(on: store)
    #expect(first.steps.count == 3)
    #expect(store.state.stage == 2)
    await store.finish()
  }

  @Test(
    "canceling exploration while waiting for clock registration completes without a false failure")
  func cancellation() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let explorer = TestStoreExplorer(
      seed: 1,
      makeStore: {
        TestStore(reducer: BugFixture(), clock: ManualTestClock(), effectTimeout: .seconds(30))
      },
      choices: { _ in
        continuation.yield(())
        return [.advance(by: .seconds(1), onceSleepersReach: 1)]
      })
    let run = Task { @MainActor in await explorer.run() }
    for await _ in stream { break }
    run.cancel()
    let result = await run.value
    #expect(result.wasCancelled)
    #expect(result.failure == nil)
    continuation.finish()
  }
}

private struct CoverageFixture: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable { case idle, loading, loaded, failed }
    var phase: Phase = .idle
  }
  enum Action: Equatable, Sendable { case tick, guarded, load, loaded, failed, reset, illegal }
  let map: PhaseMap<State, Action, State.Phase>
  static func map(calls: OSAllocatedUnfairLock<Int>) -> PhaseMap<State, Action, State.Phase> {
    PhaseMap(\.phase) {
      From(.idle) {
        On(.tick, to: .idle, selfTransitionPolicy: .allow)
        On(.guarded, targets: [.loading]) { _ in
          calls.withLock { $0 += 1 }
          return nil
        }
        On(.load, to: .loading)
      }
      From(.loading) {
        On(.loaded, to: .loaded)
        On(.failed, to: .failed)
      }
      From(.loaded) { On(.reset, to: .idle) }
    }
  }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    Reduce<State, Action, Never> { state, action in
      if action == .illegal { state.phase = .failed }
      return action == .load ? .send(.loaded) : .none
    }.phaseMap(map).reduce(into: &state, action: action)
  }
}

private struct BugFixture: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    var armed = false
    var noise = 0
  }
  enum Action: Equatable, Sendable { case arm, breakCount, noise }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .arm: state.armed = true
    case .breakCount: if state.armed { state.count = -1 }
    case .noise: state.noise += 1
    }
    return .none
  }
}

private struct ClockFixture: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable { var stage = 0 }
  enum Action: Equatable, Sendable { case start, ready }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      state.stage = 1
      return .run { send, context in
        do {
          try await context.sleep(for: .seconds(1))
          await send(.ready)
        } catch is CancellationError { return } catch { await context.reportError(error) }
      }
    case .ready:
      state.stage = 2
      return .none
    }
  }
}

@Suite("Explorer failure boundaries")
@MainActor
struct ExplorerFailureBoundaryConsistencyTests {
  @Test("effect runtime errors are preserved with their origin")
  func effectError() async {
    let explorer = TestStoreExplorer(
      seed: 5, makeStore: { TestStore(reducer: ErrorFixture()) },
      choices: { state in
        state.started ? [.finish()] : [.send(.start, source: ".start")]
      })
    let result = await explorer.run(maxSteps: 2)
    #expect(result.failure?.message.contains("fixture failure") == true)
    #expect(result.failure?.signature.contains("Error type:") == true)
    #expect(result.failure?.sourceLocation?.line ?? 0 > 0)
  }

  @Test("generator exceptions are diagnostics, never advertised as reducer reproductions")
  func generatorError() async {
    let explorer = TestStoreExplorer(
      seed: 0, makeStore: { TestStore(reducer: BugFixture()) },
      choices: { _ in
        throw FixtureFailure()
      })
    let result = await explorer.run()
    #expect(result.failure?.kind == .generator)
    #expect(!result.replayValidated)
    #expect(result.steps.isEmpty)
  }

  @Test("a correct reducer control runs the budget without a false failure")
  func correctControl() async {
    let explorer = TestStoreExplorer<BugFixture>(
      seed: 0x600,
      makeStore: {
        let store = TestStore(reducer: BugFixture())
        store.addInvariant("count nonnegative") { $0.count >= 0 }
        return store
      },
      choices: { _ in
        [.send(.noise, source: ".noise", weight: 10), .send(.arm, source: ".arm", weight: 1)]
      })
    let result = await explorer.run(maxSteps: 1_000)
    #expect(result.failure == nil)
    #expect(result.steps.count == 1_000)
  }
}

private struct FixtureFailure: Error, CustomStringConvertible {
  var description: String { "fixture failure" }
}
private struct ErrorFixture: Reducer {
  struct State: Sendable, Equatable, DefaultInitializable { var started = false }
  enum Action: Sendable, Equatable { case start }
  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.started = true
    return .run { _, context in await context.reportError(FixtureFailure()) }
  }
}

@MainActor
private func recordCoverageTick(
  _ recorder: PhaseCoverageRecorder<
    CoverageFixture.State, CoverageFixture.Action, CoverageFixture.State.Phase
  >
) async {
  let rebuilt = CoverageFixture.map(calls: .init(initialState: 0))
  let store = TestStore(reducer: CoverageFixture(map: rebuilt), phaseCoverage: recorder)
  await store.send(.tick)
  await store.finish()
}
