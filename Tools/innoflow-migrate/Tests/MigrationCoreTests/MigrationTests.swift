import Foundation
import MigrationCore
import Testing

private func migrate(_ source: String, expecting expected: String) {
  let result = InnoFlowMigration.migrate(source)
  #expect(result.blockers.isEmpty, "\(result.blockers)")
  #expect(result.source == expected)
  let repeated = InnoFlowMigration.migrate(result.source)
  #expect(repeated.source == result.source)
  #expect(repeated.changes.isEmpty)
  #expect(repeated.blockers.isEmpty)
}

@Test func effectTaskExtensionsRequireAnExplicitOutputDecision() {
  for declaration in [
    "extension EffectTask { static func helper() -> EffectTask { .none } }",
    "extension EffectTask { static func helper() -> Self { .none } }",
    "extension EffectTask { static func helper() -> EffectTask<Action> { .none } }",
    "extension EffectTask where Action == Int { static var helper: Self { .none } }",
    "extension InnoFlowCore.EffectTask { static func helper() -> Self { .none } }",
    "extension InnoFlow.EffectTask<Int> { static var helper: Self { .none } }",
    "extension `EffectTask` { static func helper() -> Self { .none } }",
    "extension EffectTask { static func check() async { let store = TestStore(reducer: F()); store.assertNoMoreActions() } }",
  ] {
    let source = "import InnoFlow\r\nimport InnoFlowTesting\r\n// 한글: preserve extension bytes\r\n" + declaration
    let result = InnoFlowMigration.migrate(source)
    #expect(result.source == source)
    #expect(result.changes.isEmpty)
    #expect(result.blockers.count == 1)
    #expect(result.blockers.first?.contains("EffectTask extension requires manual review") == true)
    let repeated = InnoFlowMigration.migrate(result.source)
    #expect(repeated.blockers == result.blockers)
  }
}

@Test func effectTaskExtensionDetectionPreservesReviewedAndForeignContracts() {
  for source in [
    "import InnoFlowCore\nextension ReducerEffect where Output == Never { static func helper() -> Self { .none } }",
    "import InnoFlowCore\nextension ReducerEffect { static func helper() -> Self { .none } }",
    "import InnoFlow\nextension Other.EffectTask { static func helper() -> Self { .none } }",
    "extension EffectTask { static func helper() -> Self { .none } }",
    "import InnoFlowCore\nfunc helper<Action: Sendable>() -> EffectTask<Action> { .none }",
  ] { migrate(source, expecting: source) }
  let qualified = "extension InnoFlowCore.EffectTask { static func helper() -> Self { .none } }"
  #expect(!InnoFlowMigration.migrate(qualified).blockers.isEmpty)
}

@Test func repairsBodyAndBuilderOutputWithoutTouchingTrivia() {
  let source = """
    import InnoFlow
    // 한글 🐦 and comments must survive byte-for-byte
    @InnoFlow struct Feature {
      var body: some InnoFlowCore.Reducer<Self.State, /* action */ Self.Action> {
        InnoFlow.CombineReducers<State, Action> {
          InnoFlowCore.Reduce<Self.State, Self.Action> { state, action in .none }
        }
      }
    }
    """
  let expected = source
    .replacingOccurrences(of: "Self.Action>", with: "Self.Action, Never>")
    .replacingOccurrences(of: "<State, Action>", with: "<State, Action, Never>")
  migrate(source, expecting: expected)
}

@Test func nestedOutputFixesExistingThirdGeneric() {
  let source = """
    @InnoFlow struct Feature {
      enum Output { case done }
      var body: some Reducer<State, Action, /* keep */ Swift.Never> {
        Reduce<State, Action> { _, _ in .none }
      }
    }
    """
  migrate(source, expecting: source
    .replacingOccurrences(of: "/* keep */ Swift.Never", with: "/* keep */ Output")
    .replacingOccurrences(of: "Reduce<State, Action>", with: "Reduce<State, Action, Output>"))
}

@Test func acceptsQualifiedNeverAndSelfOutput() {
  for source in [
    "@InnoFlow struct F { var body: some Reducer<State, Action, Swift.Never> { Reduce { _, _ in .none } } }",
    "@InnoFlow struct F { enum Output {} ; var body: some Reducer<State, Action, Self.Output> { Reduce { _, _ in .none } } }",
  ] { migrate(source, expecting: source) }
}

@Test func directNestedAliasesAndEscapedNamesCaptureOutput() {
  let source = "@InnoFlow struct F { typealias `Output` = Event; var body: some Reducer<State, Action> { Reduce { _, _ in .none } } }"
  migrate(source, expecting: source.replacingOccurrences(of: "Action>", with: "Action, Output>"))
}

@Test func preservesCRLFAndNoFinalNewline() {
  let source = "// é\r\n@InnoFlow struct F {\r\n  var body: some Reducer<State, Action> { Reduce { _, _ in .none } }\r\n}"
  migrate(source, expecting: source.replacingOccurrences(of: "Action>", with: "Action, Never>"))
}

@Test func preservesCommentsBeforeRightAngle() {
  let source = "@InnoFlow struct F { var body: some Reducer<State, Action /* trailing */\n> { Reduce { _, _ in .none } } }"
  let result = InnoFlowMigration.migrate(source)
  #expect(result.blockers.isEmpty)
  #expect(result.source.contains("/* trailing */"))
  #expect(result.source.contains(", Never"))
  #expect(InnoFlowMigration.migrate(result.source).changes.isEmpty)
}

@Test func ignoresForeignReducersAndUnannotatedFeatures() {
  for source in [
    "struct F { var body: some Reducer<State, Action> { Reduce<State, Action> { _, _ in .none } } }",
    "@Other.InnoFlow struct F { var body: some Reducer<State, Action> { Reduce<State, Action> { _, _ in .none } } }",
  ] { migrate(source, expecting: source) }
  let foreign = InnoFlowMigration.migrate("@InnoFlow struct F { var body: some Other.Reducer<State, Action> { Other.Reduce<State, Action> { _, _ in .none } } }")
  #expect(!foreign.blockers.isEmpty)
  #expect(foreign.source.contains("Other.Reduce<State, Action>"))
}

@Test func doesNotInferForeignGenericArguments() {
  let source = "@InnoFlow struct F { var body: some Reducer<ForeignState, Action> { Reduce<ForeignState, Action> { _, _ in .none } } }"
  let result = InnoFlowMigration.migrate(source)
  #expect(!result.blockers.isEmpty)
  #expect(result.source == source)
}

@Test func conditionalOutputBlocksInsteadOfChoosingConfiguration() {
  let source = """
    @InnoFlow struct F {
    #if DEBUG
      enum Output { case done }
    #endif
      var body: some Reducer<State, Action> { Reduce { _, _ in .none } }
    }
    """
  let result = InnoFlowMigration.migrate(source)
  #expect(result.source == source)
  #expect(result.blockers.contains { $0.contains("Conditional nested Output") })
}

@Test func legacyReducePromotesNeverWithoutReindentingStatements() {
  let source = """
    @InnoFlow struct F {
      enum Output { case done }
      // preserve function comment
      public func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        let effect: EffectTask<Action> = .none // keep concrete return
        return effect
      }
    }
    """
  let expected = """
    @InnoFlow struct F {
      enum Output { case done }
      // preserve function comment
      public var body: some Reducer<State, Action, Output> {
        Reduce<State, Action, Never> { state, action in
        let effect: EffectTask<Action> = .none // keep concrete return
        return effect
        }
        .promoteOutput(to: Output.self)
      }
    }
    """
  migrate(source, expecting: expected)
}

@Test func annotatedBuilderPreservesEffectTaskReturn() {
  let source = """
    @InnoFlow struct F {
      enum Output { case done }
      var body: some Reducer<State, Action> {
        Reduce<State, Action> { state, action -> EffectTask<Action> in .none }
      }
    }
    """
  let expected = source
    .replacingOccurrences(of: "Reducer<State, Action>", with: "Reducer<State, Action, Output>")
    .replacingOccurrences(of: "Reduce<State, Action>", with: "Reduce<State, Action, Never>")
    .replacingOccurrences(of: "in .none }", with: "in .none }.promoteOutput(to: Output.self)")
  migrate(source, expecting: expected)
}

@Test func unsupportedLegacyReduceRetainsSource() {
  for signature in [
    "mutating func reduce(into state: inout State, action: Action) -> EffectTask<Action>",
    "func reduce(into state: inout State, action: Action) async -> EffectTask<Action>",
    "func reduce(into state: inout State, action: Action) -> Unknown<Action>",
    "func reduce(into state: inout /* keep */ State, action: Action) -> EffectTask<Action>",
  ] {
    let source = "@InnoFlow struct F { \(signature) { .none } }"
    let result = InnoFlowMigration.migrate(source)
    #expect(result.source == source)
    #expect(!result.blockers.isEmpty)
  }
}

@Test func terminalAssertionPreservesArgumentsAndExistingAwait() {
  let source = """
    import InnoFlowTesting
    func test() async {
      let store = InnoFlowTesting.TestStore(reducer: F())
      await store.send(.start)
      await store.assertNoMoreActions(file: #filePath, line: #line) // terminal
    }
    """
  migrate(source, expecting: source.replacingOccurrences(of: "assertNoMoreActions", with: "finish"))
}

@Test func addsAwaitOnlyInsideExplicitAsyncFunction() {
  let source = """
    import InnoFlowTesting
    func test() async {
      let store = TestStore(reducer: F())
      store.assertNoMoreActions()
    }
    """
  migrate(source, expecting: source.replacingOccurrences(of: "store.assertNoMoreActions()", with: "await store.finish()"))
}

@Test func assertionUnsupportedSemanticsAreBlockers() {
  let bodies = [
    "func test() { let store = TestStore(reducer: F()); store.assertNoMoreActions() }",
    "func test() async { let store = TestStore(reducer: F()); await store.assertNoMoreActions(); await store.send(.go) }",
    "func test(store: TestStore<F>) async { await store.assertNoMoreActions() }",
    "func test() async { var store = TestStore(reducer: F()); await store.assertNoMoreActions() }",
    "func test() async { let store = TestStore(reducer: F()); await Task { await store.assertNoMoreActions() }.value }",
    "func test() async { let store = TestStore(reducer: F()); await store.assertNoMoreActions(timeout: .seconds(1)) }",
  ]
  for body in bodies {
    let source = "import InnoFlowTesting\n" + body
    let result = InnoFlowMigration.migrate(source)
    #expect(!result.blockers.isEmpty, "\(source)")
    #expect(result.source == source)
  }
}

@Test func foreignAssertionAndShadowedReceiverStayUnchanged() {
  for body in [
    "func test() async { let store = OtherStore(); await store.assertNoMoreActions() }",
    "func test() async { let store = TestStore(reducer: F()); do { let store = OtherStore(); await store.assertNoMoreActions() } }",
  ] {
    let source = "import InnoFlowTesting\n" + body
    migrate(source, expecting: source)
  }
}

@Test func serialLiteralNeedsNoEditButUnknownRangeIsBlocked() {
  migrate("import InnoFlow\nlet lane = EffectRunPolicy.serial(maxPending: 3)", expecting: "import InnoFlow\nlet lane = EffectRunPolicy.serial(maxPending: 3)")
  for value in ["-1", "capacity", "Int.max", "computeLimit()"] {
    let source = "import InnoFlow\nlet lane = EffectRunPolicy.serial(maxPending: \(value))"
    let result = InnoFlowMigration.migrate(source)
    #expect(result.source == source)
    #expect(result.blockers.contains { $0.contains("UInt") })
  }
}

@Test func flowScopeLifetimeIsNeverInvented() {
  let source = "import InnoFlow\nvar escaped = FlowScope()"
  let result = InnoFlowMigration.migrate(source)
  #expect(result.source == source)
  #expect(result.blockers.contains { $0.contains("lexical") })
}

@Test func malformedSourceNeverProducesEdits() {
  let source = "@InnoFlow struct F { var body: some Reducer<State, Action> {"
  let result = InnoFlowMigration.migrate(source)
  #expect(result.source == source)
  #expect(result.changes.isEmpty)
  #expect(!result.blockers.isEmpty)
}

@Test func stringsAndCommentsAreNotCode() {
  let source = #"let text = "store.assertNoMoreActions(); Reduce<State, Action>; FlowScope()" // Reducer<State, Action>"#
  migrate(source, expecting: source)
}

@Test func helperOutputIsNeverInferredAcrossBoundary() {
  let source = """
    @InnoFlow struct F {
      var body: some Reducer<State, Action> {
        func helper() { _ = Reduce<State, Action> { _, _ in .none } }
        return Reduce { _, _ in .none }
      }
    }
    """
  let result = InnoFlowMigration.migrate(source)
  #expect(result.source.contains("func helper() { _ = Reduce<State, Action>"))
  #expect(result.blockers.contains { $0.contains("independent output context") })
}

@Test func trailingLineCommentCannotSwallowInsertedOutput() {
  let source = """
    @InnoFlow struct F {
      var body: some Reducer<State, Action // unchanged comment
      > { Reduce { _, _ in .none } }
    }
    """
  migrate(source, expecting: source.replacingOccurrences(of: "Action //", with: "Action, Never //"))
}

@Test func existingExplicitNeverRequiresReviewedPromotion() {
  let source = "@InnoFlow struct F { enum Output {}; var body: some Reducer<State, Action, Never> { Reduce<State, Action, Never> { _, _ in .none } } }"
  let result = InnoFlowMigration.migrate(source)
  #expect(result.blockers.contains { $0.contains("reviewed output promotion") })
}

@Test func scenarioSleeperThresholdRequiresDecision() {
  let source = "import InnoFlowTesting\nlet step: TestStoreScenarioStep<F> = .advance(clock, by: .seconds(1))"
  let result = InnoFlowMigration.migrate(source)
  #expect(result.source == source)
  #expect(result.blockers.contains { $0.contains("onceSleepersReach") })
  let explicit = source.replacingOccurrences(of: "by: .seconds(1)", with: "by: .seconds(1), onceSleepersReach: 1")
  migrate(explicit, expecting: explicit)
  let clock = "import InnoFlowTesting\nfunc test() async { await clock.advance(by: .seconds(1)) }"
  migrate(clock, expecting: clock)
}

@Test func unsupportedNestedOutputDeclarationNeedsReview() {
  let source = "@InnoFlow struct F { actor Output {}; var body: some Reducer<State, Action> { Reduce { _, _ in .none } } }"
  let result = InnoFlowMigration.migrate(source)
  #expect(result.source == source)
  #expect(result.blockers.contains { $0.contains("Nested actor Output") })
}
