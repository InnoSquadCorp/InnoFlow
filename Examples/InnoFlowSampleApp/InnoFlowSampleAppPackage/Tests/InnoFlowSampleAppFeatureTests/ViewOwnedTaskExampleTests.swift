import InnoFlowCore
import InnoFlowTesting
import Testing

@testable import InnoFlowSampleAppFeature

@MainActor @Test
func viewOwnedSampleCancellationPreservesIndependentRequest() async throws {
  let clock = ManualTestClock()
  let store = Store(reducer: ViewOwnedTaskFeature(), clock: .manual(clock))
  let owned = store.send(.start)
  let independent = store.send(.start)
  try await clock.waitForSleepers(atLeast: 2)
  owned.cancel()
  await owned.finish()
  #expect(!independent.isCancelled)
  try await clock.advance(by: .milliseconds(300), onceSleepersReach: 1)
  await independent.finish()
  #expect(store.state.started == 2)
  #expect(store.state.completed == 1)
}
