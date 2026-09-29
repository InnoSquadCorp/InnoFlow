import InnoFlowTesting
import Testing

@Suite("Migration Testing Compatibility")
struct TestingCompat {
  @Test("EffectTimingRecorder Entry keeps the previous initializer shape")
  func previousInitializerShape() {
    let entry = EffectTimingRecorder.Entry(
      phase: .runStarted,
      sequence: 1,
      effectID: nil,
      actionLabel: nil,
      timestampNanos: 0
    )
    #expect(entry.sequence == 1)
  }
}
