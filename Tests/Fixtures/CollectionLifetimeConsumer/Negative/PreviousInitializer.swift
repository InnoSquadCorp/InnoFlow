import InnoFlowCore

enum Selection: Sendable { case active(Int) }
enum Action: Sendable { case value(Int) }
typealias ChildReducer = Reduce<Int, Int, Never>
typealias CaseReducer = IfCaseLet<Selection, Action, ChildReducer>

// The previous exact function signature omits source coordinates.
@MainActor func previousFactory() {
  let previousInitializer: (
    CasePath<Selection, Int>, CasePath<Action, Int>, ChildReducer, OnMissingPolicy
  ) -> CaseReducer = CaseReducer.init
  _ = previousInitializer
}

@main struct Consumer {
  static func main() {}
}
