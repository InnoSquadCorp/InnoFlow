import InnoFlowTesting
import Testing

@testable import InnoFlowSampleAppFeature

@Suite("Advanced phase testing examples")
@MainActor
struct AdvancedTestingTests {
  @Test("Observe only the exercised todo phase transitions")
  func phaseCoverage() async throws {
    let map = PhaseDrivenTodoFeature.phaseMap
    let coverage = PhaseCoverageRecorder(map)
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: PhaseDrivenTodoFeature(todoService: EmptyTodoService()),
      phaseCoverage: coverage,
      clock: clock
    )
    await store.send(.loadTodos, through: map) { $0.phase = .loading }
    try await clock.advance(by: .milliseconds(120), onceSleepersReach: 1)
    await store.receive(._loaded([]), through: map) { $0.phase = .loaded }
    let report = coverage.report()
    #expect(report.covered.count == 2)
    #expect(report.uncovered.count == 5)
    #expect(report.mermaid().contains("uncovered"))
    coverage.assertPhaseCoverage(minimum: .fraction(2.0 / 7.0))
    await store.finish()
  }

  @Test("Seeded state and clock choices reproduce a successful load")
  func seededSearch() async {
    let explorer = TestStoreExplorer<PhaseDrivenTodoFeature>(
      seed: 0x600,
      makeStore: {
        let store = TestStore(
          reducer: PhaseDrivenTodoFeature(todoService: EmptyTodoService()),
          clock: ManualTestClock()
        )
        store.addInvariant("failed phase has an error") {
          $0.phase != .failed || $0.errorMessage != nil
        }
        return store
      },
      generator: { context in
        switch context.state.phase {
        case .idle:
          return [
            .send(.setShouldFail(false), source: ".setShouldFail(false)", weight: 1),
            .send(.loadTodos, source: ".loadTodos", weight: 8),
          ]
        case .loading where context.elapsedTime < .milliseconds(120):
          return [.advance(by: .milliseconds(120), onceSleepersReach: 1)]
        case .loading:
          return [.receive(._loaded([]), source: "._loaded([])")]
        case .loaded, .failed:
          return []
        }
      })
    let first = await explorer.run()
    let second = await explorer.run()
    #expect(first.failure == nil)
    #expect(first.steps == second.steps)
    #expect(first.scenario.seed == 0x600)
  }
}

private struct EmptyTodoService: SampleTodoServiceProtocol {
  func loadTodos(shouldFail: Bool) async throws -> [SampleTodo] { [] }
}
