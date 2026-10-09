// MARK: - TestStoreTerminalVerificationTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCore
@testable import InnoFlowTesting

@Suite("TestStore Terminal Verification Tests", .serialized)
@MainActor
struct TestStoreTerminalVerificationTests {
  @Test("deinit reports a buffered action when finish is omitted")
  func deinitReportsBufferedActionWhenFinishIsOmitted() async {
    var failures: [String] = []
    var locations: [(file: String, line: UInt)] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, file, line in
      failures.append(message)
      locations.append((String(describing: file), line))
    }

    await store?.send(
      .emitResponse,
      file: "TerminalVerification.swift",
      line: 123
    )
    #expect(failures.isEmpty)

    store = nil

    #expect(failures.count == 1)
    #expect(failures.first?.contains("response") == true)
    #expect(locations.first?.file == "TerminalVerification.swift")
    #expect(locations.first?.line == 123)
  }

  @Test("deinit reports at the latest receive source location")
  func deinitReportsAtLatestReceiveSourceLocation() async {
    var locations: [(file: String, line: UInt)] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { _, file, line in
      locations.append((String(describing: file), line))
    }

    await store?.send(.idle)
    store?.queue.enqueue(.response, context: nil)
    store?.queue.enqueue(.secondResponse, context: nil)
    await store?.receive(
      .response,
      timeout: .zero,
      file: "TerminalReceive.swift",
      line: 456
    )
    store = nil

    #expect(locations.count == 1)
    #expect(locations.first?.file == "TerminalReceive.swift")
    #expect(locations.first?.line == 456)
  }

  @Test("deinit reports and cancels an active effect when finish is omitted")
  func deinitReportsActiveEffectWhenFinishIsOmitted() async {
    let gate = RunStartGate()
    var failures: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature(gate: gate)
    )
    weak var weakStore: TestStore<TerminalVerificationFeature>?
    weakStore = store
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store?.send(.wait)
    #expect(store?.finishActivity.snapshot.runCount == 1)

    store = nil

    #expect(failures.count == 1)
    #expect(failures.first?.contains("run: 1") == true)
    #expect(weakStore == nil)
    await gate.open()
  }

  @Test("deinit ignores buffered actions invalidated by cancellation")
  func deinitIgnoresInvalidatedBufferedActions() async {
    var failures: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store?.send(.idle)
    if let store {
      let sequence = store.nextSequence()
      store.queue.enqueue(
        .response,
        context: store.makeEffectContext(sequence: sequence)
      )
      _ = store.markCancelledAll(upTo: sequence)
    }

    store = nil

    #expect(failures.isEmpty)
  }

  @Test("failed finish is not reported again during deinit")
  func failedFinishDoesNotReportAgainDuringDeinit() async {
    var failures: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }
    _ = store?.finishActivity.begin(.run)

    await store?.finish(timeout: .zero)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("Timed out") == true)

    store = nil

    #expect(failures.count == 1)
  }

  @Test("stale activity after failed finish does not rearm terminal verification")
  func staleActivityAfterFailedFinishDoesNotRearmTerminalVerification() async {
    var failures: [String] = []
    var staleRunTask: Task<Void, Never>?
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    if let store {
      let staleSequence = store.nextSequence()
      let staleContext = store.makeEffectContext(sequence: staleSequence)
      _ = store.finishActivity.begin(.run)
      await store.finish(timeout: .zero)
      #expect(failures.count == 1)

      staleRunTask = await store.startRun(
        priority: nil,
        operation: { _, _ in },
        context: staleContext
      )
    }
    store = nil

    #expect(failures.count == 1)
    _ = await staleRunTask?.result
  }

  @Test("a new send after finish requires terminal verification again")
  func newSendAfterFinishRearmsTerminalVerification() async {
    var failures: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store?.finish()
    await store?.send(.emitResponse)
    store = nil

    #expect(failures.count == 1)
    #expect(failures.first?.contains("response") == true)
  }

  @Test("a late action after finish requires terminal verification again")
  func lateActionAfterFinishRearmsTerminalVerification() async {
    var failures: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store?.finish()
    store?.deliverAction(.response, context: nil)
    store = nil

    #expect(failures.count == 1)
    #expect(failures.first?.contains("response") == true)
  }

  @Test("effect activity starting after finish requires terminal verification again")
  func effectActivityAfterFinishRearmsTerminalVerification() async {
    let gate = RunStartGate()
    var failures: [String] = []
    var runTask: Task<Void, Never>?
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    await store?.finish()
    if let store {
      runTask = await store.startRun(
        priority: nil,
        operation: { _, _ in await gate.wait() },
        context: nil
      )
      #expect(store.finishActivity.snapshot.runCount == 1)
    }
    store = nil

    #expect(failures.count == 1)
    #expect(failures.first?.contains("run: 1") == true)
    await gate.open()
    _ = await runTask?.result
  }

  @Test("warning exhaustivity reports terminal omission without failing")
  func warningExhaustivityReportsTerminalOmission() async {
    var failures: [String] = []
    var warnings: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.exhaustivity = .off(showSkippedAssertions: true)
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }
    store?.skippedAssertionReporter = { message, _, _ in
      warnings.append(message)
    }

    await store?.send(.emitResponse)
    store = nil

    #expect(failures.isEmpty)
    #expect(warnings.count == 1)
    #expect(warnings.first?.contains("skipped terminal verification") == true)
    #expect(warnings.first?.contains("response") == true)
  }

  @Test("silent non-exhaustive mode suppresses terminal omission diagnostics")
  func silentNonExhaustiveModeSuppressesTerminalDiagnostics() async {
    var failures: [String] = []
    var warnings: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.exhaustivity = .off
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }
    store?.skippedAssertionReporter = { message, _, _ in
      warnings.append(message)
    }

    await store?.send(.emitResponse)
    store = nil

    #expect(failures.isEmpty)
    #expect(warnings.isEmpty)
  }

  @Test("idle TestStore does not require finish")
  func idleTestStoreDoesNotRequireFinish() {
    var failures: [String] = []
    var store: TestStore<TerminalVerificationFeature>? = TestStore(
      reducer: TerminalVerificationFeature()
    )
    store?.assertionFailureReporter = { message, _, _ in
      failures.append(message)
    }

    store = nil

    #expect(failures.isEmpty)
  }
}

private struct TerminalVerificationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case emitResponse
    case wait
    case response
    case secondResponse
    case idle
  }

  let gate: RunStartGate?

  init(gate: RunStartGate? = nil) {
    self.gate = gate
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .emitResponse:
      return .send(.response)
    case .wait:
      guard let gate else { return .none }
      return .run { _ in
        await gate.wait()
      }
    case .response, .secondResponse:
      return .none
    case .idle:
      return .none
    }
  }
}
