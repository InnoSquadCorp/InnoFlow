import InnoFlowCore
import InnoFlowTesting

// Expected 6.0 compile failure: a return-type-changing method is not a Void
// function value, even though ordinary discarded-result statements still work.
@main
struct LegacyVoidFunctionValue {
  @MainActor
  static func main() async {
    let store = TestStore(reducer: ConsumerFeature())
    let legacy:
      @MainActor (
        ConsumerFeature.Action,
        ((inout ConsumerFeature.State) -> Void)?,
        StaticString,
        UInt
      ) async -> Void = store.send
    await legacy(.start, nil, #file, #line)
  }
}
