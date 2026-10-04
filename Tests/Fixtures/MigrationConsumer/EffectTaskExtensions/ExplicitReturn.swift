import InnoFlowCore

extension EffectTask {
  static func legacyExplicitHelper() -> EffectTask<Action> { .none }
}

let noOutput: EffectTask<Int> = .legacyExplicitHelper()

#if MIGRATION_OUTPUT_CHECK
// Even on the wider receiver, the explicit alias return remains Never-output.
let stillNoOutput: EffectTask<Int> = ReducerEffect<Int, String>.legacyExplicitHelper()
#endif
