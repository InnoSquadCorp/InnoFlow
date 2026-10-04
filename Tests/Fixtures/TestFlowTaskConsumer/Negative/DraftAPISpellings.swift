import InnoFlowCore
import InnoFlowTesting

private struct DraftParentState: Sendable { var child: ConsumerFeature.State? = .init() }

@main
struct Consumer {
  @MainActor
  static func main() async {
    let store = TestStore(reducer: ConsumerFeature())
    let task = await store.send(.output)
    let scoped = store.scope(
      state: \.value,
      action: CasePath<ConsumerFeature.Action, ConsumerFeature.Action>(
        embed: { $0 }, extract: { $0 }))
    let outputPath = CasePath<Int, Int>(embed: { $0 }, extract: { $0 })
    _ = task
    _ = scoped
    _ = outputPath
    #if DRAFT_ALIAS
      let _: TestFlowTask = task
    #elseif DRAFT_DISPATCH_FILE
      await task.finish(file: "Draft.swift")
    #elseif DRAFT_OUTPUT_FILE
      await store.receiveOutput(0, file: "Draft.swift")
    #elseif DRAFT_PREDICATE_FILE
      _ = await store.receiveOutput(where: { $0 == 0 }, file: "Draft.swift")
    #elseif DRAFT_CASE_FILE
      _ = await store.receiveOutput(outputPath, file: "Draft.swift")
    #elseif DRAFT_SCOPED_OUTPUT_FILE
      await scoped.receiveOutput(0, file: "Draft.swift")
    #elseif DRAFT_SCOPED_PREDICATE_FILE
      _ = await scoped.receiveOutput(where: { $0 == 0 }, file: "Draft.swift")
    #elseif DRAFT_SCOPED_CASE_FILE
      _ = await scoped.receiveOutput(outputPath, file: "Draft.swift")
    #elseif DRAFT_INVARIANT_FILE
      _ = TestStoreInvariant<ConsumerFeature.State>(
        "nonnegative", file: "Draft.swift", predicate: { $0.value >= 0 })
    #elseif DRAFT_ADD_INVARIANT_FILE
      store.addInvariant("nonnegative", file: "Draft.swift", predicate: { $0.value >= 0 })
    #elseif DRAFT_SCENARIO_SEND_FILE
      _ = TestStoreScenarioStep<ConsumerFeature>.send(.output, file: "Draft.swift")
    #elseif DRAFT_SCENARIO_RECEIVE_FILE
      _ = TestStoreScenarioStep<ConsumerFeature>.receive(.response, file: "Draft.swift")
    #elseif DRAFT_SCENARIO_OUTPUT_FILE
      _ = TestStoreScenarioStep<ConsumerFeature>.receiveOutput(0, file: "Draft.swift")
    #elseif DRAFT_SCENARIO_FINISH_FILE
      _ = TestStoreScenarioStep<ConsumerFeature>.finish(file: "Draft.swift")
    #else
      let parent = Reduce<DraftParentState, ConsumerFeature.Action, Int> { _, _ in .none }
      let action = CasePath<ConsumerFeature.Action, ConsumerFeature.Action>(
        embed: { $0 }, extract: { $0 })
      #if DRAFT_CHILD_LABEL
        _ = parent.optionalChild(
          state: \.child, action: action, instanceID: { $0.value }, child: ConsumerFeature())
      #elseif DRAFT_INITIALIZER_LABEL
        _ = OptionalChildLifetime(
          parent: parent, state: \.child, action: action, instanceID: { $0.value },
          child: ConsumerFeature())
      #else
        #error("Select one removed draft spelling")
      #endif
    #endif
  }
}
