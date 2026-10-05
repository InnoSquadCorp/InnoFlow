import InnoFlowCore

extension EffectTask {
  static func legacySelfHelper() -> Self { .none }
}

let noOutput: EffectTask<Int> = .legacySelfHelper()

#if MIGRATION_OUTPUT_CHECK
  // The alias extension also reaches the underlying type with real Output.
  let withOutput: ReducerEffect<Int, String> = .legacySelfHelper()
#endif
