// MARK: - StoreRootInterpreterHandoffTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import Synchronization
import Testing

@testable import InnoFlowCoreTestSupport

// A `Store` walks the effects it interprets one at a time, in the order it
// created their interpreter tasks. An interpreter whose task runs while an
// earlier walk has not finished — that walk suspended, here to read the
// clock — starts in the MainActor job queued when that walk finishes.
//
// These tests fix that job without blocking or sleeping. The reducer of an
// action a walk delivers runs in the job in which that walk finishes, and
// queues a job from there, `<action>/1`, which queues `<action>/2` when it
// runs. MainActor tasks run in the order they are created, so an interpreter
// that waited for that walk, started behind `<action>/1` and before it runs,
// delivers between the two: wherever the earlier walk resumed.

private let throttleID = EffectID<String>("root-handoff-throttle")
private let secondThrottleID = EffectID<String>("root-handoff-second-throttle")
private let immediateID = EffectID<String>("root-handoff-immediate")

private func stepID(_ step: Int) -> EffectID<String> {
  EffectID("root-handoff-step-\(step)")
}

private final class OrderRecorder: Sendable {
  private let events = Mutex<[String]>([])

  func add(_ event: String) { events.withLock { $0.append(event) } }

  var all: [String] { events.withLock { $0 } }
}

/// A store clock whose reads stay suspended until the test releases them, so
/// the test decides when a throttle's interpreter resumes its walk. Each read
/// is resumed through a continuation resumed on the MainActor.
@MainActor
private final class ClockReadGate {
  private var readers: [CheckedContinuation<Void, Never>] = []
  private let instant = ContinuousClock.now
  /// The priority of each reading task when its read returned.
  private let priorities = Mutex<[TaskPriority]>([])

  var suspendedReadCount: Int { readers.count }

  nonisolated var prioritiesAfterRead: [TaskPriority] { priorities.withLock { $0 } }

  private func read() async -> ContinuousClock.Instant {
    await withCheckedContinuation { readers.append($0) }
    return instant
  }

  func releaseReads() {
    let suspended = readers
    readers.removeAll()
    for reader in suspended { reader.resume() }
  }

  nonisolated var clock: StoreClock {
    StoreClock(
      now: {
        let instant = await self.read()
        // Still the interpreter task that reads the clock.
        let priority = Task.currentPriority
        self.priorities.withLock { $0.append(priority) }
        return instant
      },
      // Only cancellation ends a throttle window in these tests.
      sleep: { duration in try await Task.sleep(for: duration) }
    )
  }
}

/// A store clock for a throttle walked behind another one. The first read
/// stays suspended until the test releases it. A later read keeps its task
/// suspended until that task runs at `.high`, or until a scaled deadline
/// passes, and records the priority its task had then.
@MainActor
private final class EscalationClock {
  private var firstReader: CheckedContinuation<Void, Never>?
  private var readCount = 0
  private let instant = ContinuousClock.now
  private let priorities = Mutex<[TaskPriority]>([])

  var isFirstReadSuspended: Bool { firstReader != nil }

  /// The priority of each later reading task when its read returned.
  nonisolated var laterReadPriorities: [TaskPriority] { priorities.withLock { $0 } }

  func releaseFirstRead() {
    firstReader?.resume()
    firstReader = nil
  }

  /// Suspends the first read until the test releases it.
  ///
  /// - Returns: Whether this was the first read.
  private func readFirst() async -> Bool {
    readCount += 1
    guard readCount == 1 else { return false }
    await withCheckedContinuation { firstReader = $0 }
    return true
  }

  private func currentInstant() -> ContinuousClock.Instant { instant }

  nonisolated var clock: StoreClock {
    StoreClock(
      now: {
        guard await !self.readFirst() else { return await self.currentInstant() }
        // Only a task awaiting this one can raise it while it reads.
        let deadline = ContinuousClock.now.advanced(by: scaledTestDeadline(.seconds(5)))
        while Task.currentPriority.rawValue < TaskPriority.high.rawValue,
          ContinuousClock.now < deadline
        {
          await Task.yield()
        }
        let priority = Task.currentPriority
        self.priorities.withLock { $0.append(priority) }
        return await self.currentInstant()
      },
      // Only cancellation ends a throttle window in these tests.
      sleep: { duration in try await Task.sleep(for: duration) }
    )
  }
}

private struct HandoffFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    /// A leading throttle around `.send(.lead)`: its interpreter suspends to
    /// read the clock before it delivers.
    case throttled
    /// A leading throttle around `.send(.secondLead)` under another ID.
    case throttledAgain
    /// `.send(.lead)` under an ID: its interpreter finishes in its first job.
    case immediate
    case lead
    case secondLead
    /// `.send(.stepped(step))` under the step's ID.
    case step(Int)
    case stepped(Int)
    /// `.send(.stepped(1))` under an animation: a walk that reaches the send
    /// with a cancelled dispatch records a dropped action.
    case animatedStep
    /// A run under the first step's ID that reports the priority it runs at.
    case reportingStep
    case ranAt(TaskPriority)
  }

  let recorder: OrderRecorder
  /// The recorded names of the reduced actions whose reduction queues a
  /// MainActor job: that job records `<name>/1` and queues one that records
  /// `<name>/2`.
  var jobs: Set<String> = []
  /// Runs in every `<name>/1` job, after it recorded.
  var inFirstJob: (@MainActor @Sendable () -> Void)?

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .throttled:
      return EffectTask<Action>.send(.lead).throttle(throttleID, for: .seconds(60))
    case .throttledAgain:
      return EffectTask<Action>.send(.secondLead).throttle(secondThrottleID, for: .seconds(60))
    case .immediate:
      return EffectTask<Action>.send(.lead).cancellable(immediateID)
    case .lead:
      record("lead")
      return .none
    case .secondLead:
      record("secondLead")
      return .none
    case .step(let step):
      return EffectTask<Action>.send(.stepped(step)).cancellable(stepID(step))
    case .stepped(let step):
      record("s\(step)")
      return .none
    case .animatedStep:
      return EffectTask<Action>.send(.stepped(1)).applyingAnimation(
        EffectAnimation(description: "root-handoff") { updates in updates() })
    case .reportingStep:
      return EffectTask<Action>.run { send in await send(.ranAt(Task.currentPriority)) }
        .cancellable(stepID(1))
    case .ranAt(let priority):
      record("priority=\(priority.rawValue)")
      return .none
    }
  }

  /// Records a reduced action and queues its job, if any, from the MainActor
  /// job that reduces the action: the job of the interpreter delivering it.
  private func record(_ name: String) {
    recorder.add(name)
    guard jobs.contains(name) else { return }
    Task { @MainActor [recorder, inFirstJob] in
      recorder.add("\(name)/1")
      inFirstJob?()
      Task { @MainActor in recorder.add("\(name)/2") }
    }
  }
}

@MainActor
private final class StoreBox {
  var store: Store<HandoffFeature>?
}

/// Returns once every MainActor job queued before the call has run.
@MainActor
private func mainActorBarrier() async {
  await Task { @MainActor in }.value
}

/// Polls until `condition` holds. The deadline is a failure backstop scaled
/// with `INNOFLOW_TEST_WAIT_SCALE`.
@MainActor
private func waitFor(
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @MainActor () -> Bool
) async {
  let deadline = ContinuousClock.now.advanced(by: scaledTestDeadline(.seconds(10)))
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("The awaited condition was not reached in time", sourceLocation: sourceLocation)
      return
    }
    try? await Task.sleep(for: .milliseconds(1))
  }
}

@MainActor
@Suite("Store root interpreter handoff", .serialized, .timeLimit(.minutes(2)))
struct StoreRootInterpreterHandoffTests {
  /// Every order below is fixed by the order in which MainActor jobs are
  /// queued, so each scenario must give the same order every time.
  private static let repetitions = 30

  /// Sends `first`, then runs `send`, whose interpreters come behind it, and
  /// returns once all of their tasks have run. Behind `throttled`, whose
  /// interpreter is then suspended in its clock read, they wait.
  private func lineUp(
    behind first: HandoffFeature.Action = .throttled,
    in store: Store<HandoffFeature>,
    gate: ClockReadGate,
    _ send: @MainActor () -> Void
  ) async {
    store.send(first)
    send()
    await mainActorBarrier()
    guard first == .throttled else { return }
    await waitFor { gate.suspendedReadCount == 1 }
  }

  @Test("An interpreter that waited starts in the job queued when the walk before it finished")
  func waitingInterpreterStartsRightBehindItsPredecessor() async {
    var orders: [[String]: Int] = [:]
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder, jobs: ["lead"]),
        initialState: .init(), clock: gate.clock)

      await lineUp(in: store, gate: gate) { store.send(.step(1)) }
      // The walk of `throttled` resumes, delivers `lead`, whose reduction
      // queues `lead/1`, and finishes: the step's walk starts behind
      // `lead/1`, and ahead of `lead/2`, which `lead/1` queues when it runs.
      gate.releaseReads()
      await waitFor { recorder.all.count == 4 }
      orders[recorder.all, default: 0] += 1
      await store.cancelAllEffects()
    }
    #expect(orders == [["lead", "lead/1", "s1", "lead/2"]: Self.repetitions])
  }

  @Test("Control: an interpreter behind a finished walk starts in its own job")
  func interpreterBehindFinishedWalkStartsInItsOwnJob() async {
    var orders: [[String]: Int] = [:]
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder, jobs: ["lead"]),
        initialState: .init(), clock: gate.clock)

      // `immediate`'s interpreter finishes in its first job, so the step's
      // task, created before `lead/1`, walks ahead of it.
      await lineUp(behind: .immediate, in: store, gate: gate) { store.send(.step(1)) }
      await waitFor { recorder.all.count == 4 }
      orders[recorder.all, default: 0] += 1
    }
    #expect(orders == [["lead", "s1", "lead/1", "lead/2"]: Self.repetitions])
  }

  @Test("Each waiting interpreter starts in the job queued when the one before it finished")
  func waitingLineStartsOneJobApart() async {
    var orders: [[String]: Int] = [:]
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder, jobs: ["lead", "s1", "s2", "s3"]),
        initialState: .init(), clock: gate.clock)

      await lineUp(in: store, gate: gate) {
        for step in 1...4 { store.send(.step(step)) }
      }
      // Each walk starts behind the first job of the walk before it and
      // ahead of that job's follow-up, and queues its own first job behind
      // that follow-up.
      gate.releaseReads()
      await waitFor { recorder.all.count == 13 }
      orders[recorder.all, default: 0] += 1
      await store.cancelAllEffects()
    }
    #expect(
      orders == [
        [
          "lead", "lead/1", "s1", "lead/2", "s1/1", "s2", "s1/2", "s2/1", "s3", "s2/2", "s3/1",
          "s4", "s3/2",
        ]: Self.repetitions
      ])
  }

  @Test("A dispatch cancelled while its interpreter waits keeps its turn and walks nothing")
  func cancelledWaitingInterpreterKeepsItsTurn() async {
    var orders: [[String]: Int] = [:]
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder, jobs: ["lead"]),
        initialState: .init(), clock: gate.clock)

      var cancelled = FlowTask.completed
      var last = FlowTask.completed
      await lineUp(in: store, gate: gate) {
        cancelled = store.send(.step(1))
        last = store.send(.step(2))
      }
      cancelled.cancel()

      // The cancelled interpreter keeps its turn, the job behind `lead/1`;
      // the next interpreter starts in the job queued when that turn ends,
      // behind `lead/2`.
      gate.releaseReads()
      await waitFor { last.isFinished }
      #expect(cancelled.isFinished)
      orders[recorder.all, default: 0] += 1
      await store.cancelAllEffects()
    }
    #expect(orders == [["lead", "lead/1", "lead/2", "s2"]: Self.repetitions])
  }

  @Test("A cancelled interpreter that waited walks nothing, like one that did not wait")
  func cancelledWaitingInterpreterRecordsNoDrop() async {
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder),
        initialState: .init(), clock: gate.clock,
        instrumentation: .init(didDropAction: { _ in recorder.add("drop") }))

      var cancelled = FlowTask.completed
      await lineUp(in: store, gate: gate) { cancelled = store.send(.animatedStep) }
      cancelled.cancel()

      // A walk would reach the animated send and record its drop: the task
      // that takes the turn is cancelled with the dispatch and skips it.
      gate.releaseReads()
      await waitFor { cancelled.isFinished }
      #expect(recorder.all == ["lead"])
      await store.cancelAllEffects()
    }
  }

  @Test("An ID cancelled while its interpreter waits is skipped when the turn comes")
  func idCancelledWhileWaitingIsSkipped() async {
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder, jobs: ["lead"]),
        initialState: .init(), clock: gate.clock)

      var skipped = FlowTask.completed
      var last = FlowTask.completed
      await lineUp(in: store, gate: gate) {
        skipped = store.send(.step(1))
        last = store.send(.step(2))
      }
      // The waiting effect declares its work under the step's ID; the walk
      // finds that work cancelled when it starts.
      await store.cancelEffects(identifiedBy: stepID(1))

      gate.releaseReads()
      await waitFor { skipped.isFinished && last.isFinished }
      #expect(recorder.all == ["lead", "lead/1", "lead/2", "s2"])
      await store.cancelAllEffects()
    }
  }

  @Test("Cancelling every effect while interpreters wait ends every dispatch and walks nothing")
  func cancellingAllEffectsWhileWaitingEndsEveryDispatch() async {
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder),
        initialState: .init(), clock: gate.clock)

      let throttled = store.send(.throttled)
      let first = store.send(.step(1))
      let second = store.send(.step(2))
      await mainActorBarrier()
      await waitFor { gate.suspendedReadCount == 1 }
      await store.cancelAllEffects()

      gate.releaseReads()
      await waitFor { throttled.isFinished && first.isFinished && second.isFinished }
      #expect(!recorder.all.contains("s1"))
      #expect(!recorder.all.contains("s2"))
    }
  }

  @Test("A store released before a waiting interpreter's turn ends that interpreter's dispatch")
  func storeReleasedBeforeWaitingTurnEndsItsDispatch() async {
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let box = StoreBox()
      // `lead/1` runs after the throttled walk finished, which no longer
      // holds the store, and before the waiting interpreter's turn.
      box.store = Store(
        reducer: HandoffFeature(
          recorder: recorder, jobs: ["lead"], inFirstJob: { box.store = nil }),
        initialState: .init(), clock: gate.clock)
      weak let released = box.store

      box.store?.send(.throttled)
      let first = box.store?.send(.step(1)) ?? .completed
      let second = box.store?.send(.step(2)) ?? .completed
      await mainActorBarrier()
      await waitFor { gate.suspendedReadCount == 1 }

      gate.releaseReads()
      await waitFor { first.isFinished && second.isFinished }
      #expect(recorder.all == ["lead", "lead/1", "lead/2"])
      #expect(released == nil)
    }
  }

  @Test("An interpreter that waits keeps the one before it at least at its own priority")
  func waitingInterpreterRaisesTheOneBeforeIt() async {
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder),
        initialState: .init(), clock: gate.clock)

      // The throttled interpreter is created at low priority and suspends.
      // Nothing awaits the sending tasks, so nothing else raises a priority.
      Task(priority: .low) { @MainActor in _ = store.send(.throttled) }
      await mainActorBarrier()
      await mainActorBarrier()
      await waitFor { gate.suspendedReadCount == 1 }
      // The one behind it is created at high priority and waits for it.
      Task(priority: .high) { @MainActor in _ = store.send(.step(1)) }
      await mainActorBarrier()
      await mainActorBarrier()

      gate.releaseReads()
      await waitFor { recorder.all.count == 2 }
      #expect(gate.prioritiesAfterRead == [.high])
      await store.cancelAllEffects()
    }
  }

  @Test("An interpreter that waits keeps raising the walk before it once that walk was handed off")
  func waitingInterpreterRaisesAHandedOffWalk() async {
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let clock = EscalationClock()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder),
        initialState: .init(), clock: clock.clock)

      // Two throttles are created at low priority: the first suspends to read
      // the clock, and the second waits for it. Nothing awaits the sending
      // task, so nothing else raises a priority.
      Task(priority: .low) { @MainActor in
        _ = store.send(.throttled)
        _ = store.send(.throttledAgain)
      }
      await mainActorBarrier()
      await mainActorBarrier()
      await waitFor { clock.isFirstReadSuspended }
      // The one behind them is created at high priority and waits for the
      // second throttle's interpreter task.
      Task(priority: .high) { @MainActor in _ = store.send(.step(1)) }
      await mainActorBarrier()
      await mainActorBarrier()

      // The first walk finishes, and the second is handed off to a task at
      // the low priority it was created with, which suspends to read the
      // clock. Only the waiting interpreter, which now awaits that task, can
      // raise it.
      clock.releaseFirstRead()
      await waitFor { recorder.all.count == 3 }
      #expect(recorder.all == ["lead", "secondLead", "s1"])
      #expect(clock.laterReadPriorities == [.high])
      await store.cancelAllEffects()
    }
  }

  @Test(
    "An interpreter runs at the priority of the task that reduced its action, waiting or not",
    arguments: [HandoffFeature.Action.throttled, .immediate])
  fileprivate func interpreterKeepsThePriorityOfItsReduction(first: HandoffFeature.Action) async {
    for _ in 0..<Self.repetitions {
      let recorder = OrderRecorder()
      let gate = ClockReadGate()
      let store = Store(
        reducer: HandoffFeature(recorder: recorder),
        initialState: .init(), clock: gate.clock)

      // Nothing awaits the sending task, so nothing raises its priority.
      await lineUp(behind: first, in: store, gate: gate) {
        Task(priority: .low) { @MainActor in _ = store.send(.reportingStep) }
      }
      await mainActorBarrier()
      gate.releaseReads()
      await waitFor { recorder.all.count == 2 }
      #expect(recorder.all == ["lead", "priority=\(TaskPriority.low.rawValue)"])
      await store.cancelAllEffects()
    }
  }
}
