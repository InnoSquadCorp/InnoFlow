import InnoFlowCore
import InnoFlowTesting
import Testing

@testable import InnoFlowSampleAppFeature

@MainActor @Test
func optionalChildCloseAndReopenDropsOldOutput() async throws {
  let clock = ManualTestClock()
  let store = Store(reducer: OptionalChildLifetimeExample(), clock: .manual(clock))
  store.send(.open(7))
  let oldID = store.state.child?.instanceID
  let old = store.send(.child(.load), capturingOutputs: .unbounded)
  try await clock.waitForSleepers(atLeast: 1)
  store.send(.close)
  await old.finish()
  var oldOutputs = old.outputs.makeAsyncIterator()
  #expect(await oldOutputs.next() == nil)
  store.send(.open(7))
  #expect(store.state.child?.instanceID != oldID)
  let fresh = store.send(.child(.load), capturingOutputs: .unbounded)
  try await clock.advance(by: .seconds(1), onceSleepersReach: 1)
  await fresh.finish()
  var outputs = fresh.outputs.makeAsyncIterator()
  #expect(await outputs.next() == .loaded(7))
  #expect(await outputs.next() == nil)
}
