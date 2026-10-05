import InnoFlowCore

extension EffectTask {
  static func legacyBareHelper() -> EffectTask { .none }
}

let result: EffectTask<Int> = .legacyBareHelper()
