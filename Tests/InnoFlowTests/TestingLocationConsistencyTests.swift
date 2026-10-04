import Foundation
import InnoFlowCore
import Testing

@testable import InnoFlowTesting

#if canImport(XCTest)
  import XCTest
#endif

@Suite("Testing call-site and scoped-output consistency", .serialized)
@MainActor
struct TestingLocationConsistencyTests {
  @Test("Swift Testing records the exact supplied four-coordinate source location")
  func swiftTestingUsesCallSite() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    await withKnownIssue("Intentional state mismatch verifies the real reporter") {
      await store.send(
        .increment, fileID: "LocationTests/Explicit.swift", filePath: "/fixtures/Explicit.swift",
        line: 91, column: 8)
    } matching: { issue in
      issue.sourceLocation
        == SourceLocation(
          fileID: "LocationTests/Explicit.swift", filePath: "/fixtures/Explicit.swift", line: 91,
          column: 8)
    }
    await store.finish()
  }

  @Test("default source arguments are captured at the caller")
  func defaultsUseCaller() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    var locations: [TestStoreSourceLocation] = []
    store.issueReporter = { _, location in locations.append(location) }
    let expectedLine = #line + 1
    await store.send(.increment)
    #expect(locations.count == 1)
    #expect(locations[0].fileID.description == #fileID)
    #expect(locations[0].filePath.description == #filePath)
    #expect(locations[0].line == expectedLine)
    #expect(locations[0].column > 0)
    await store.finish()
  }

  @Test("explicit legacy file overload remains supported with a defined column")
  func legacyFileOverload() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    var locations: [TestStoreSourceLocation] = []
    store.issueReporter = { _, location in locations.append(location) }
    await store.send(.increment, file: "Legacy.swift", line: 18)
    #expect(locations.count == 1)
    #expect(locations[0].fileID.description == "Legacy.swift")
    #expect(locations[0].filePath.description == "Legacy.swift")
    #expect(locations[0].line == 18)
    #expect(locations[0].column == 1)
    await store.finish()
  }

  @Test("scoped and phase helpers forward every source coordinate")
  func scopedAndPhaseLocations() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    let scoped = store.scope(state: \.count, action: LocationConsistencyFeature.Action.path)
    var locations: [TestStoreSourceLocation] = []
    store.issueReporter = { _, location in locations.append(location) }
    await scoped.send(
      .increment, fileID: "Tests/Scope.swift", filePath: "/Scope.swift", line: 30, column: 9)
    await store.send(
      .increment, tracking: \.phase, through: PhaseTransitionGraph<Int>([:]),
      fileID: "Tests/Phase.swift", filePath: "/Phase.swift", line: 40, column: 10)
    await store.send(.start)
    await scoped.receive(
      .increment, fileID: "Tests/Receive.swift", filePath: "/Receive.swift", line: 50, column: 11)
    #expect(
      locations.map { $0.fileID.description } == [
        "Tests/Scope.swift", "Tests/Phase.swift", "Tests/Receive.swift",
      ])
    #expect(locations.map(\.line) == [30, 40, 50])
    #expect(locations.map(\.column) == [9, 10, 11])
    await store.finish()
  }

  @Test("dispatch/global finish and deinit preserve complete source locations")
  func terminalLocations() async {
    var store: TestStore<LocationConsistencyFeature>? = TestStore(
      reducer: LocationConsistencyFeature())
    var locations: [TestStoreSourceLocation] = []
    store?.issueReporter = { _, location in locations.append(location) }
    let dispatch = await store!.send(.output)
    await dispatch.finish(
      fileID: "Tests/Dispatch.swift", filePath: "/Dispatch.swift", line: 60, column: 12)
    await store!.finish(
      fileID: "Tests/Finish.swift", filePath: "/Finish.swift", line: 70, column: 13)
    await store!.send(
      .output, fileID: "Tests/Deinit.swift", filePath: "/Deinit.swift", line: 80, column: 14)
    store = nil
    #expect(
      locations.map { $0.filePath.description } == [
        "/Dispatch.swift", "/Finish.swift", "/Deinit.swift",
      ])
    #expect(locations.map(\.column) == [12, 13, 14])
  }

  @Test("scenario decoration and invariant diagnostics keep their configured origins")
  func scenarioAndInvariantLocations() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    var locations: [TestStoreSourceLocation] = []
    var messages: [String] = []
    store.issueReporter = { message, location in
      messages.append(message)
      locations.append(location)
    }
    let scenario = TestStoreScenario<LocationConsistencyFeature>(steps: [
      .send(
        .increment, fileID: "Tests/Scenario.swift", filePath: "/Scenario.swift", line: 90,
        column: 15)
    ])
    _ = await scenario.run(on: store)
    store.addInvariant(
      "zero", fileID: "Tests/Invariant.swift", filePath: "/Invariant.swift", line: 100, column: 16
    ) { $0.count == 0 }
    await store.send(.increment) { $0.count = 2 }
    #expect(messages[0].contains("Scenario step"))
    #expect(
      locations.map { $0.fileID.description } == ["Tests/Scenario.swift", "Tests/Invariant.swift"])
    #expect(locations.map(\.column) == [15, 16])
    await store.finish()
  }

  @Test("asynchronous run failures retain the originating public call site")
  func asynchronousFailureLocation() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    var locations: [TestStoreSourceLocation] = []
    store.issueReporter = { _, location in locations.append(location) }
    await store.send(
      .fail, fileID: "Tests/Run.swift", filePath: "/Run.swift", line: 110, column: 17)
    for run in store.runningTasks.values.map(\.task) { _ = await run.result }
    #expect(locations.count == 1)
    #expect(locations[0].fileID.description == "Tests/Run.swift")
    #expect(locations[0].filePath.description == "/Run.swift")
    #expect(locations[0].line == 110)
    #expect(locations[0].column == 17)
    await store.finish()
  }

  @Test("scoped exact and predicate outputs use the shared root queue", arguments: [false, true])
  func scopedOutputOverloads(exhaustive: Bool) async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    let scoped = store.scope(state: \.count, action: LocationConsistencyFeature.Action.path)
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.output)
    await scoped.receiveOutput(0, timeout: .zero)
    await store.send(.output)
    #expect(await scoped.receiveOutput(where: { $0 == 0 }, timeout: .zero) == 0)
    await store.finish()
  }

  @Test("scoped predicate output honors non-exhaustive action progress and total timeout")
  func scopedOutputProgressAndTimeout() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    let scoped = store.scope(state: \.count, action: LocationConsistencyFeature.Action.path)
    store.exhaustivity = .off
    await store.send(.outputAfterAction)
    #expect(await scoped.receiveOutput(where: { $0 == 0 }) == 0)
    var locations: [TestStoreSourceLocation] = []
    store.issueReporter = { _, location in locations.append(location) }
    await scoped.receiveOutput(
      99, timeout: .zero, fileID: "Tests/Output.swift", filePath: "/Output.swift", line: 120,
      column: 18)
    #expect(locations.count == 1)
    #expect(locations[0].column == 18)
    await store.finish()
  }

  @Test("scoped predicate output cancellation does not turn into a timeout")
  func scopedOutputCancellation() async {
    let store = TestStore(reducer: LocationConsistencyFeature())
    let scoped = store.scope(state: \.count, action: LocationConsistencyFeature.Action.path)
    store.exhaustivity = .off
    let waiting = AsyncStream<Void>.makeStream()
    var failures: [String] = []
    store.issueReporter = { message, _ in failures.append(message) }
    store.finishActivity.waitTimeoutObserver = { _ in waiting.continuation.yield(()) }
    let receiving = Task { await scoped.receiveOutput(where: { $0 == 1 }, timeout: .seconds(60)) }
    var waits = waiting.stream.makeAsyncIterator()
    _ = await waits.next()
    receiving.cancel()
    #expect(await receiving.value == nil)
    #expect(failures.isEmpty)
    #expect(store.finishActivity.pendingWaiterCount == 0)
    await store.finish()
  }

  @Test("structural diff penetrates hidden descriptions and retains nested collection paths")
  func structuralDiffSnapshots() {
    let hiddenBefore = HiddenDescription(items: [.init(title: "a")])
    let hiddenAfter = HiddenDescription(items: [.init(title: "b"), .init(title: "c")])
    let diff = renderStateDiff(expected: hiddenBefore, actual: hiddenAfter)
    #expect(diff?.contains(#"items[0].title: expected "a", actual "b""#) == true)
    #expect(diff?.contains("items[1]: expected <missing>") == true)
    #expect(
      renderStateDiff(expected: hiddenBefore, actual: hiddenAfter, lineLimit: 1)?.split(
        separator: "\n"
      ).count == 1)
    #expect(renderStateDiff(expected: hiddenBefore, actual: hiddenAfter, lineLimit: 0) == nil)
  }

  @Test("different enum cases with equal payloads still produce a structural diff")
  func enumCaseDiff() {
    enum Value {
      case first(Int)
      case second(Int)
    }
    let diff = renderStateDiff(expected: Value.first(1), actual: Value.second(1))
    #expect(diff?.contains("first(1)") == true)
    #expect(diff?.contains("second(1)") == true)
    #expect(renderStateDiff(expected: Value.first(1), actual: Value.first(1)) == nil)
  }
}

private struct HiddenDescription: CustomDebugStringConvertible {
  struct Item { var title: String }
  var items: [Item]
  var debugDescription: String { "redacted" }
}

private struct LocationConsistencyFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    var phase = 0
  }
  enum Action: Equatable, Sendable {
    case increment, start, output, outputAfterAction, fail
    static let path = CasePath<Action, Action>(embed: { $0 }, extract: { $0 })
  }
  typealias Output = Int
  struct Failure: Error {}
  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .increment:
      state.count += 1
      return .none
    case .start: return .send(.increment)
    case .output: return Self.output(state.count)
    case .outputAfterAction: return .send(.output)
    case .fail:
      return .run { (_: EffectContext) async throws -> LocationFailureSequence<Action> in
        throw Failure()
      }
    }
  }
}

#if canImport(XCTest)
  final class XCTestReportingLocationTests: XCTestCase {
    private var capturingExpectedFailure = false
    private var captured: [(String?, UInt)] = []

    #if os(Linux)
      override func recordFailure(
        withDescription description: String, inFile filePath: String, atLine lineNumber: Int,
        expected: Bool
      ) {
        if capturingExpectedFailure {
          captured.append((filePath, UInt(lineNumber)))
        } else {
          super.recordFailure(
            withDescription: description, inFile: filePath, atLine: lineNumber, expected: expected)
        }
      }
    #else
      override func record(_ issue: XCTIssue) {
        if capturingExpectedFailure {
          let location = issue.sourceCodeContext.location
          captured.append((location?.fileURL.path, UInt(location?.lineNumber ?? 0)))
        } else {
          super.record(issue)
        }
      }

    #endif

    func testUsesXCTestWhenNoSwiftTestingTestIsCurrent() {
      XCTAssertNil(Test.current)
      capturingExpectedFailure = true
      _ = assertCasePathExtracts(
        1, via: CasePath<Int, Int>(embed: { $0 }, extract: { _ in nil }),
        fileID: "Tests/XCTestProbe.swift", filePath: "/fixtures/XCTestProbe.swift", line: 314,
        column: 19)
      capturingExpectedFailure = false
      XCTAssertEqual(captured.count, 1)
      XCTAssertEqual(captured.first?.0, "/fixtures/XCTestProbe.swift")
      XCTAssertEqual(captured.first?.1, 314)
    }

    #if !os(Linux)
      func testExpectedFailureIsAttributedToUserSource() {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
          issue.sourceCodeContext.location?.fileURL.path == "/fixtures/XCTestExpected.swift"
            && issue.sourceCodeContext.location?.lineNumber == 271
        }
        XCTExpectFailure("The user-source assertion is expected", options: options) {
          _ = assertCasePathExtracts(
            1, via: CasePath<Int, Int>(embed: { $0 }, extract: { _ in nil }),
            fileID: "Tests/XCTestExpected.swift", filePath: "/fixtures/XCTestExpected.swift",
            line: 271, column: 20)
        }
      }
    #endif
  }
#endif

private struct LocationFailureSequence<Element: Sendable>: AsyncSequence, Sendable {
  struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    mutating func next() async throws -> Element? { nil }
  }
  func makeAsyncIterator() -> AsyncIterator { .init() }
}
