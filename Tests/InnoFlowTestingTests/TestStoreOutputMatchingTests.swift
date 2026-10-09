import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("TestStore output matching")
@MainActor
struct TestStoreOutputMatchingTests {
  @Test("predicates receive non-equatable outputs and return the matched value")
  func predicateReceivesNonEquatableOutput() async {
    let store = TestStore(reducer: NonEquatableOutputFeature())
    await store.send(.emit(42))

    let output = await store.receiveOutput(where: { $0.value == 42 }, timeout: .zero)

    #expect(output?.value == 42)
    await store.finish()
  }

  @Test("case paths distinguish an optional nil payload from no match")
  func casePathPreservesOptionalNil() async {
    let store = TestStore(reducer: NonEquatableOutputFeature())
    await store.send(.emit(nil))
    let path = CasePath<NonEquatableOutputFeature.Output, Int?>(
      embed: { .init(value: $0) },
      extract: { .some($0.value) }
    )

    let result: Int?? = await store.receiveOutput(path, timeout: .zero)

    #expect(result != nil)
    #expect(result! == nil)
    await store.finish()
  }

  @Test("exhaustive matching reports the first mismatch without consuming the next output")
  func exhaustiveMismatchStopsImmediately() async {
    let store = TestStore(reducer: NonEquatableOutputFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    await store.send(.emit(1))
    await store.send(.emit(2))

    let result = await store.receiveOutput(
      where: { $0.value == 2 }, description: "value two", timeout: .zero
    )

    #expect(result == nil)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("Received unexpected output") == true)
    #expect(failures.first?.contains("value two") == true)
    let next = await store.receiveOutput(where: { $0.value == 2 }, timeout: .zero)
    #expect(next?.value == 2)
    await store.finish()
  }

  @Test("all output overloads honor non-exhaustive skipping", arguments: [false, true])
  func nonExhaustiveSkipping(showWarnings: Bool) async {
    let store = TestStore(reducer: IntegerOutputFeature())
    store.exhaustivity = .off(showSkippedAssertions: showWarnings)
    var warnings: [String] = []
    store.skippedAssertionReporter = { message, _, _ in warnings.append(message) }
    for value in 1...6 { await store.send(value) }

    await store.receiveOutput(2)
    let predicateValue = await store.receiveOutput(where: { $0 == 4 })
    let path = CasePath<Int, String>(
      embed: { Int($0) ?? 0 },
      extract: { $0 == 6 ? String($0) : nil }
    )
    let pathValue = await store.receiveOutput(path)

    #expect(predicateValue == 4)
    #expect(pathValue == "6")
    #expect(warnings.count == (showWarnings ? 3 : 0))
    await store.finish()
  }

  @Test("skipping buffered mismatches cannot reset the total deadline")
  func skippedOutputHonorsTotalDeadline() async {
    let store = TestStore(reducer: IntegerOutputFeature())
    store.exhaustivity = .off
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    await store.send(1)
    await store.send(2)

    await store.receiveOutput(2, timeout: .zero)

    #expect(failures.count == 1)
    #expect(failures.first?.contains("timed out") == true)
    // The timeout must leave the next buffered output available.
    await store.receiveOutput(2, timeout: .zero)
    await store.finish()
    #expect(failures.count == 1)
  }

  @Test("invalidated outputs are skipped within the same total deadline")
  func invalidatedOutputHonorsTotalDeadline() async {
    let store = TestStore(reducer: IntegerOutputFeature())
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let registry = EffectCancellationScopeRegistry()
    let (scope, lease) = registry.makeScopeAndInterpreterLease(
      sequence: 1, potentialCancellationIDs: []
    )
    let context = EffectExecutionContext.managedRoot(
      cancellationScope: scope, interpreterLease: lease, sequence: 1
    )
    store.deliverOutput(1, context: context)
    store.deliverOutput(2, context: nil)
    scope.cancelAll()

    await store.receiveOutput(2, timeout: .zero)

    #expect(failures.count == 1)
    #expect(failures.first?.contains("timed out") == true)
    await store.receiveOutput(2, timeout: .zero)
    await store.finish()
  }

  @Test("cancelling output reception does not produce a false timeout")
  func cancellationDoesNotReportTimeout() async {
    let store = TestStore(reducer: IntegerOutputFeature(), effectTimeout: .seconds(60))
    var failures: [String] = []
    store.assertionFailureReporter = { message, _, _ in failures.append(message) }
    let ready = AsyncStream<Void>.makeStream()
    let receiver = Task {
      ready.continuation.yield(())
      return await store.receiveOutput(where: { $0 == 1 })
    }
    var started = ready.stream.makeAsyncIterator()
    _ = await started.next()

    receiver.cancel()
    let result = await receiver.value

    #expect(result == nil)
    #expect(failures.isEmpty)
    await store.finish()
  }
}

// Manual core reducers keep these testing-runtime fixtures independent of macros.
private struct NonEquatableOutputFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}
  enum Action: Sendable { case emit(Int?) }
  struct Output: Sendable { let value: Int? }

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .emit(let value): Self.output(.init(value: value))
    }
  }
}

private struct IntegerOutputFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}
  typealias Action = Int
  typealias Output = Int

  func reduce(into state: inout State, action: Int) -> ReducerEffect<Int, Int> {
    Self.output(action)
  }
}
