import Foundation
import InnoFlowTesting

@main struct Consumer {
  static func main() {
    _ = EffectTimingRecorder.Entry(
      phase: .runStarted, sequence: 1, effectID: nil, actionLabel: nil, dispatchID: UUID(),
      timestampNanos: 1)
  }
}
