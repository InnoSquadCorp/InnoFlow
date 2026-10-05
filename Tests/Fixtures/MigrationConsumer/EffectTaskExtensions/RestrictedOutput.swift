import InnoFlowCore

extension ReducerEffect where Output == Never {
  static func reviewedNoOutputHelper() -> Self { .none }
}

let noOutput: EffectTask<Int> = .reviewedNoOutputHelper()

#if MIGRATION_OUTPUT_CHECK
  // An explicit Output restriction prevents widening the helper's contract.
  let withOutput: ReducerEffect<Int, String> = .reviewedNoOutputHelper()
#endif
