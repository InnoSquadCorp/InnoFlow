// MARK: - TestFixtures.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI
import Testing
import os

@testable import InnoFlow
@testable import InnoFlowTesting

// MARK: - Fixtures

struct CounterFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    init() {}
    init(count: Int) { self.count = count }
  }

  enum Action: Equatable, Sendable {
    case increment
    case decrement
    case reset
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .increment:
      state.count += 1
      return .none
    case .decrement:
      state.count -= 1
      return .none
    case .reset:
      state.count = 0
      return .none
    }
  }
}

struct AsyncFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var value: String = ""
    var isLoading = false
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .load:
      state.isLoading = true
      return .run { send in
        await send(._loaded("Hello, InnoFlow v2"))
      }
    case ._loaded(let value):
      state.value = value
      state.isLoading = false
      return .none
    }
  }
}

struct EmissionOrderingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case triggerImmediate
    case triggerRun
    case received(String)
  }

  let probe: InstrumentationProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .triggerImmediate:
      return .send(.received("immediate"))

    case .triggerRun:
      return .run { send in
        await send(.received("run"))
      }

    case .received(let value):
      probe.record("reduce:\(value)")
      return .none
    }
  }
}

struct ContextClockFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case record(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, context in
        await send(.record("started"))
        do {
          try await context.sleep(for: .milliseconds(50))
          try await context.checkCancellation()
          await send(.record("finished"))
        } catch is CancellationError {
          await send(.record("cancelled"))
        } catch {
          return
        }
      }
      .cancellable("context-clock")

    case .record(let entry):
      state.log.append(entry)
      return .none
    }
  }
}

actor CancellationCheckProbe {
  private(set) var started = 0
  private(set) var ready = 0
  private(set) var passed = 0
  private(set) var cancelled = 0

  func markStarted() {
    started += 1
  }

  func markReady() {
    ready += 1
  }

  func markPassed() {
    passed += 1
  }

  func markCancelled() {
    cancelled += 1
  }
}

actor LateSendGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var isWaiting = false

  func wait() async {
    await withCheckedContinuation { continuation in
      isWaiting = true
      self.continuation = continuation
    }
  }

  func open() {
    isWaiting = false
    continuation?.resume()
    continuation = nil
  }
}

actor OrderedIntProbe {
  private var values: [Int] = []

  func append(_ value: Int) {
    values.append(value)
  }

  func snapshot() -> [Int] {
    values
  }
}

struct CancellationCheckFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {}

  enum Action: Equatable, Sendable {
    case start
  }

  let probe: CancellationCheckProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { _, context in
        await probe.markStarted()
        do {
          try await context.sleep(for: .milliseconds(10))
          await probe.markReady()
          try await context.checkCancellation()
          await probe.markPassed()

          while true {
            try await context.checkCancellation()
            await Task.yield()
          }
        } catch is CancellationError {
          await probe.markCancelled()
        } catch {
          return
        }
      }
      .cancellable("context-check")
    }
  }
}

struct StoreReleaseDropFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case _completed(String)
  }

  let gate: LateSendGate

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, _ in
        await gate.wait()
        await send(._completed("late-value"))
      }
      .cancellable("store-release-drop")

    case ._completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

struct ImmediateSendFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var logs: [String] = []
  }

  enum Action: Equatable, Sendable {
    case trigger
    case _logged(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .trigger:
      return .send(._logged("event"))
    case ._logged(let value):
      state.logs.append(value)
      return .none
    }
  }
}

final class ReducerDepthProbe: Sendable {
  private struct State {
    var currentDepth = 0
    var maxDepth = 0
    var actions: [String] = []
  }

  private let state = OSAllocatedUnfairLock<State>(initialState: .init())

  var currentDepth: Int {
    state.withLock { $0.currentDepth }
  }

  var maxDepth: Int {
    state.withLock { $0.maxDepth }
  }

  var actions: [String] {
    state.withLock { $0.actions }
  }

  func enter(_ action: String) {
    state.withLock { state in
      state.currentDepth += 1
      state.maxDepth = max(state.maxDepth, state.currentDepth)
      state.actions.append(action)
    }
  }

  func leave() {
    state.withLock { $0.currentDepth -= 1 }
  }
}

final class ObservationProbe: Sendable {
  private let countLock = OSAllocatedUnfairLock<Int>(initialState: 0)

  var count: Int {
    countLock.withLock { $0 }
  }

  func recordChange() {
    countLock.withLock { $0 += 1 }
  }
}

final class SelectionTransformProbe: Sendable {
  private let countLock = OSAllocatedUnfairLock<Int>(initialState: 0)

  var count: Int {
    countLock.withLock { $0 }
  }

  func record() {
    countLock.withLock { $0 += 1 }
  }
}

final class InstrumentationProbe: Sendable {
  private let eventsLock = OSAllocatedUnfairLock<[String]>(initialState: [])

  var events: [String] {
    eventsLock.withLock { $0 }
  }

  func record(_ event: String) {
    eventsLock.withLock { $0.append(event) }
  }
}

@MainActor
final class ProjectionObserverTestProbe: ProjectionObserver {
  private let refreshResult: Bool
  private(set) var refreshCount = 0

  init(refreshResult: Bool = false) {
    self.refreshResult = refreshResult
  }

  func refreshFromParentStore() -> Bool {
    refreshCount += 1
    return refreshResult
  }
}

struct ProjectionObserverSnapshot: Equatable {
  var tracked: Int
  var other: Int
}

struct QueueDispatchFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var logs: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case first
    case second
    case loadAsync
    case _loadedAsync
  }

  let probe: ReducerDepthProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    probe.enter(String(describing: action))
    defer { probe.leave() }

    switch action {
    case .start:
      state.logs.append("start")
      return .send(.first)

    case .first:
      state.logs.append("first")
      return .send(.second)

    case .second:
      state.logs.append("second")
      return .none

    case .loadAsync:
      state.logs.append("loadAsync")
      return .run { send in
        await send(._loadedAsync)
      }

    case ._loadedAsync:
      state.logs.append("loadedAsync")
      return .none
    }
  }
}

struct MergeOrderingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var emitted: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case _emitted(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .merge(
        .run { send, context in
          try? await context.sleep(for: .milliseconds(30))
          await send(._emitted("slow"))
        },
        .run { send, context in
          try? await context.sleep(for: .milliseconds(5))
          await send(._emitted("fast"))
        }
      )

    case ._emitted(let value):
      state.emitted.append(value)
      return .none
    }
  }
}

struct ParentChildOrchestrationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var log: [String] = []
    var isRefreshing = false
    var profileLoaded = false
    var permissionsLoaded = false
  }

  enum Action: Equatable, Sendable {
    case refresh
    case child(ChildAction)
    case _finished
  }

  enum ChildAction: Equatable, Sendable {
    case profileLoaded
    case permissionsLoaded
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .refresh:
      state.isRefreshing = true
      state.log.append("refresh")
      return .concatenate(
        .send(.child(.profileLoaded)),
        .send(.child(.permissionsLoaded)),
        .send(._finished)
      )

    case .child(.profileLoaded):
      state.profileLoaded = true
      state.log.append("profile")
      return .none

    case .child(.permissionsLoaded):
      state.permissionsLoaded = true
      state.log.append("permissions")
      return .none

    case ._finished:
      state.isRefreshing = false
      state.log.append("finished")
      return .none
    }
  }
}

struct LongRunningOrchestrationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var progress: [Int] = []
    var finished = false
  }

  enum Action: Equatable, Sendable {
    case start
    case _progress(Int)
    case _finished
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .concatenate(
        .send(._progress(0)),
        .run { send in
          try? await Task.sleep(for: .milliseconds(10))
          await send(._progress(50))
        },
        .run { send in
          try? await Task.sleep(for: .milliseconds(10))
          await send(._finished)
        }
      )
      .cancellable("sync-pipeline", cancelInFlight: true)

    case ._progress(let value):
      state.progress.append(value)
      return .none

    case ._finished:
      state.finished = true
      return .none
    }
  }
}

struct CancellableFeature: Reducer {
  let delay: Duration

  init(delay: Duration = .milliseconds(200)) {
    self.delay = delay
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var completed: [Int] = []
    var requested = 0
  }

  enum Action: Equatable, Sendable {
    case start(Int)
    case _completed(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let value):
      state.requested += 1
      return .run { send in
        do {
          try await Task.sleep(for: delay)
          await send(._completed(value))
        } catch {
          // Cancellation should stop action emission.
        }
      }
      .cancellable("load", cancelInFlight: true)

    case ._completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

struct RunEmissionBoundaryFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var events: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(String)
    case cancel
    case _record(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let label):
      return .run { send, context in
        do {
          await send(._record("\(label)-1"))
          try await context.sleep(for: .milliseconds(80))
          try await context.checkCancellation()
          await send(._record("\(label)-2"))
          await send(._record("\(label)-3"))
        } catch is CancellationError {
          return
        } catch {
          return
        }
      }
      .cancellable("run-boundary", cancelInFlight: true)

    case .cancel:
      return .cancel("run-boundary")

    case ._record(let event):
      state.events.append(event)
      return .none
    }
  }
}

struct DirectSendCancellationBoundaryFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var events: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case _record(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .concatenate(
        .cancel("direct-send-boundary"),
        .send(._record("late")).cancellable("direct-send-boundary")
      )

    case ._record(let event):
      state.events.append(event)
      return .none
    }
  }
}

struct LazyMappedEffectFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case cancel
    case value(String)
  }

  enum ChildAction: Equatable, Sendable {
    case immediate(String)
    case delayed(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      let childEffect: EffectTask<ChildAction> = .concatenate(
        .send(.immediate("first")),
        .run { send, context in
          do {
            try await context.sleep(for: .milliseconds(60))
            try await context.checkCancellation()
            await send(.delayed("second"))
          } catch is CancellationError {
            return
          } catch {
            return
          }
        }
      )
      .cancellable("lazy-mapped-effect", cancelInFlight: true)

      return childEffect.map { childAction in
        switch childAction {
        case .immediate(let value), .delayed(let value):
          return .value(value)
        }
      }

    case .cancel:
      return .cancel("lazy-mapped-effect")

    case .value(let value):
      state.values.append(value)
      return .none
    }
  }
}

struct DeepLazyMapStressFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case start(Int)
    case cancel
    case value(Int)
  }

  let chainDepth: Int
  let cancellationID: StaticEffectID
  let includesAsyncTail: Bool

  init(
    chainDepth: Int,
    cancellationID: StaticEffectID = "deep-lazy-map-stress",
    includesAsyncTail: Bool = true
  ) {
    self.chainDepth = chainDepth
    self.cancellationID = cancellationID
    self.includesAsyncTail = includesAsyncTail
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let seed):
      var childEffect: EffectTask<Int> =
        .concatenate(
          .send(seed),
          includesAsyncTail
            ? .run { send in
              try? await Task.sleep(for: .milliseconds(15))
              await send(seed + 1)
            }
            : .send(seed + 1)
        )
        .cancellable(cancellationID, cancelInFlight: true)

      for _ in 0..<chainDepth {
        childEffect = childEffect.map { $0 + 1 }
      }

      return childEffect.map(Action.value)

    case .cancel:
      return .cancel(cancellationID)

    case .value(let value):
      state.values.append(value)
      return .none
    }
  }
}

struct UncooperativeCancellableFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case _completed(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send in
        // Intentionally ignores cancellation and still tries to emit.
        let jitter = Int.random(in: 20...80)
        try? await Task.sleep(for: .milliseconds(jitter))
        await send(._completed("late-value"))
      }
      .cancellable("uncooperative")

    case ._completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

struct CompositeUncooperativeFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case start(Int)
    case _completed(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let value):
      return .concatenate(
        .merge(
          .run { send in
            let jitter = Int.random(in: 10...30)
            try? await Task.sleep(for: .milliseconds(jitter))
            await send(._completed(value * 10 + 1))
          },
          .run { send in
            let jitter = Int.random(in: 20...40)
            try? await Task.sleep(for: .milliseconds(jitter))
            await send(._completed(value * 10 + 2))
          }
        ),
        .run { send in
          let jitter = Int.random(in: 30...60)
          try? await Task.sleep(for: .milliseconds(jitter))
          await send(._completed(value * 10 + 3))
        }
      )
      .cancellable("composite-uncooperative")

    case ._completed(let value):
      state.completed.append(value)
      return .none
    }
  }
}

struct ScopedCounterFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    struct Child: Equatable, Sendable {
      var count = 0
    }
    var child = Child()
  }

  enum Action: Equatable, Sendable {
    case childIncrement

    static let selfCasePath = CasePath<Self, Self>(
      embed: { $0 },
      extract: { $0 }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .childIncrement:
      state.child.count += 1
      return .none
    }
  }
}

@InnoFlow
struct ScopedBindableChildFeature {
  struct Child: Equatable, Sendable {
    @BindableField var step = 1
    var title = "Child"
    var note = "Ready"
    var priority = 0
    var isEnabled = true
    var version = 1
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child = Child()
    var unrelated = 0
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
    case setUnrelated(Int)
  }

  enum ChildAction: Equatable, Sendable {
    case setStep(Int)
    case setTitle(String)
    case setNote(String)
    case setPriority(Int)
    case setEnabled(Bool)
    case setVersion(Int)
    case setSnapshot(step: Int, title: String, note: String)
    case setSelectionProbe(
      step: Int,
      title: String,
      note: String,
      priority: Int,
      isEnabled: Bool,
      version: Int
    )
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .child(.setStep(let step)):
        state.child.step = max(1, step)
        return .none

      case .child(.setTitle(let title)):
        state.child.title = title
        return .none

      case .child(.setNote(let note)):
        state.child.note = note
        return .none

      case .child(.setPriority(let priority)):
        state.child.priority = priority
        return .none

      case .child(.setEnabled(let isEnabled)):
        state.child.isEnabled = isEnabled
        return .none

      case .child(.setVersion(let version)):
        state.child.version = version
        return .none

      case .child(.setSnapshot(let step, let title, let note)):
        state.child.step = max(1, step)
        state.child.title = title
        state.child.note = note
        return .none

      case .child(
        .setSelectionProbe(
          let step,
          let title,
          let note,
          let priority,
          let isEnabled,
          let version
        )
      ):
        state.child.step = max(1, step)
        state.child.title = title
        state.child.note = note
        state.child.priority = priority
        state.child.isEnabled = isEnabled
        state.child.version = version
        return .none

      case .setUnrelated(let value):
        state.unrelated = value
        return .none
      }
    }
  }
}

@InnoFlow
struct ScopedCollectionFeature {
  struct Todo: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    @BindableField var isDone = false
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var todos: [Todo] = [
      Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "One"),
      Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Two"),
      Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, title: "Three"),
    ]
  }

  enum Action: Equatable, Sendable {
    case todo(id: UUID, action: TodoAction)
    case moveLastToFront
    case appendTodo(id: UUID, title: String)
    case removeTodo(id: UUID)

    static func todoAction(id: UUID, action: TodoAction) -> Self {
      .todo(id: id, action: action)
    }
  }

  enum TodoAction: Equatable, Sendable {
    case setDone(Bool)
  }

  struct TodoRowFeature: Reducer {
    func reduce(into state: inout Todo, action: TodoAction) -> EffectTask<TodoAction> {
      switch action {
      case .setDone(let isDone):
        state.isDone = isDone
        return .none
      }
    }
  }

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .todo:
          return .none

        case .moveLastToFront:
          guard let last = state.todos.popLast() else { return .none }
          state.todos.insert(last, at: 0)
          return .none

        case .appendTodo(let id, let title):
          state.todos.append(.init(id: id, title: title))
          return .none

        case .removeTodo(let id):
          state.todos.removeAll { $0.id == id }
          return .none
        }
      }

      ForEachReducer(
        state: \.todos,
        action: Action.todoActionPath,
        reducer: TodoRowFeature()
      )
    }
  }
}

@InnoFlow
struct ScopedTestHarnessFeature {
  struct Child: Equatable, Sendable {
    var log: [String] = []
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child = Child()
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case start
    case finished
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .child(.start):
        state.child.log.append("start")
        return .send(.child(.finished))

      case .child(.finished):
        state.child.log.append("finished")
        return .none
      }
    }
  }
}

protocol DependencyBundleServiceProtocol: Sendable {
  func message() async -> String
}

actor DependencyBundleService: DependencyBundleServiceProtocol {
  private let value: String

  init(value: String = "bundle-ready") {
    self.value = value
  }

  func message() async -> String {
    value
  }
}

@InnoFlow
struct DependencyBundleFeature {
  struct Dependencies: Sendable {
    let service: any DependencyBundleServiceProtocol
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var output = ""
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
  }

  let dependencies: Dependencies

  init(service: any DependencyBundleServiceProtocol = DependencyBundleService()) {
    self.dependencies = .init(service: service)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .load:
        let service = dependencies.service
        return .run { send, _ in
          let value = await service.message()
          await send(._loaded(value))
        }

      case ._loaded(let value):
        state.output = value
        state.log.append("loaded \(value)")
        return .none
      }
    }
  }
}

@InnoFlow
struct IfLetFeature {
  struct Child: Equatable, Sendable {
    var count = 0
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child: Child? = .init()
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
    case dismiss
    case present
  }

  enum ChildAction: Equatable, Sendable {
    case increment
    case finished
  }

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .send(.finished)

      case .finished:
        return .none
      }
    }
  }

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .dismiss:
          state.child = nil
          return .none

        case .present:
          state.child = .init()
          return .none

        case .child(.finished):
          state.log.append("optional-finished")
          return .none

        case .child:
          return .none
        }
      }

      IfLet(
        state: \.child,
        action: Action.childCasePath,
        reducer: ChildReducer()
      )
    }
  }
}

@InnoFlow
struct IfCaseLetFeature {
  struct Child: Equatable, Sendable {
    var count = 0
    var completions = 0
  }

  enum State: Equatable, Sendable, DefaultInitializable {
    case idle
    case child(Child)

    init() {
      self = .idle
    }
  }

  enum Action: Equatable, Sendable {
    case activate
    case deactivate
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case increment
    case finished
  }

  static let childStateCasePath = CasePath<State, Child>(
    embed: State.child,
    extract: { state in
      guard case .child(let child) = state else { return nil }
      return child
    }
  )

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .send(.finished)

      case .finished:
        return .none
      }
    }
  }

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .activate:
          state = .child(.init())
          return .none

        case .deactivate:
          state = .idle
          return .none

        case .child(.finished):
          guard case .child(var child) = state else { return .none }
          child.completions += 1
          state = .child(child)
          return .none

        case .child:
          return .none
        }
      }

      IfCaseLet(
        state: Self.childStateCasePath,
        action: Action.childCasePath,
        reducer: ChildReducer()
      )
    }
  }
}

@InnoFlow
struct IfLetIgnoreFeature {
  struct Child: Equatable, Sendable {
    var count = 0
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var child: Child? = .init()
    var untouched: Int = 7
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case increment
  }

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .none
      }
    }
  }

  var body: some Reducer<State, Action> {
    IfLet(
      state: \.child,
      action: Action.childCasePath,
      reducer: ChildReducer(),
      onMissing: .ignore
    )
  }
}

@InnoFlow
struct IfCaseLetIgnoreFeature {
  struct Child: Equatable, Sendable {
    var count = 0
  }

  enum State: Equatable, Sendable, DefaultInitializable {
    case idle
    case child(Child)

    init() { self = .idle }
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)
  }

  enum ChildAction: Equatable, Sendable {
    case increment
  }

  static let childStateCasePath = CasePath<State, Child>(
    embed: State.child,
    extract: { state in
      guard case .child(let child) = state else { return nil }
      return child
    }
  )

  struct ChildReducer: Reducer {
    typealias State = Child
    typealias Action = ChildAction

    func reduce(into state: inout Child, action: ChildAction) -> EffectTask<ChildAction> {
      switch action {
      case .increment:
        state.count += 1
        return .none
      }
    }
  }

  var body: some Reducer<State, Action> {
    IfCaseLet(
      state: Self.childStateCasePath,
      action: Action.childCasePath,
      reducer: ChildReducer(),
      onMissing: .ignore
    )
  }
}

@InnoFlow(phaseManaged: true)
struct PhaseManagedFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    var phase: Phase = .idle
    var output: String?
    var errorMessage: String?
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
    case _failed(String)
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(Action.loadedCasePath, to: .loaded)
        On(Action.failedCasePath, to: .failed)
      }
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .load:
        state.errorMessage = nil
        return .none
      case ._loaded(let output):
        state.output = output
        return .none
      case ._failed(let message):
        state.errorMessage = message
        return .none
      }
    }
  }
}

struct InstrumentationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case startDelayed
    case trailingThrottle(Int)
    case received(String)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .startDelayed:
      return .run { send in
        try? await Task.sleep(for: .milliseconds(50))
        await send(.received("delayed"))
      }
      .cancellable("instrumented-delayed")

    case .trailingThrottle(let value):
      return .send(.received("throttled-\(value)"))
        .throttle("instrumented-throttle", for: .milliseconds(80), leading: false, trailing: true)

    case .received(let value):
      state.log.append(value)
      return .none
    }
  }
}

struct RuntimeMetricsFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var completed = 0
  }

  enum Action: Equatable, Sendable {
    case start
    case _completed
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .run { send, context in
        do {
          try await context.sleep(for: .milliseconds(100))
          try await context.checkCancellation()
          await send(._completed)
        } catch is CancellationError {
          return
        } catch {
          return
        }
      }
      .cancellable("runtime-metrics")

    case ._completed:
      state.completed += 1
      return .none
    }
  }
}

struct BindingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    @BindableField var step = 1
  }

  enum Action: Equatable, Sendable {
    case setStep(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .setStep(let step):
      state.step = max(1, step)
      return .none
    }
  }
}

struct PhaseDrivenFeature: Reducer {
  enum Phase: String, Equatable, Hashable, Sendable {
    case idle
    case loading
    case loaded
    case failed
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var phase: Phase = .idle
    var value = ""
    init() {}
  }

  enum Action: Equatable, Sendable {
    case load
    case _loaded(String)
    case _failed
  }

  static let graph = PhaseTransitionGraph<Phase>([
    .init(from: .idle, to: .loading),
    .init(from: .loading, to: .loaded),
    .init(from: .loading, to: .failed),
    .init(from: .failed, to: .loading),
  ])

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .load:
      state.phase = .loading
      return .send(._loaded("done"))
    case ._loaded(let value):
      state.phase = .loaded
      state.value = value
      return .none
    case ._failed:
      state.phase = .failed
      return .none
    }
  }
}

struct DebounceFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var emitted: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case trigger(Int)
    case _emitted(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .trigger(let value):
      return EffectTask.send(._emitted(value))
        .debounce("debounce-effect", for: .milliseconds(60))
    case ._emitted(let value):
      state.emitted.append(value)
      return .none
    }
  }
}

struct ThrottleFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var emitted: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case trigger(Int)
    case _emitted(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .trigger(let value):
      return EffectTask.send(._emitted(value))
        .throttle("throttle-effect", for: .milliseconds(80))
    case ._emitted(let value):
      state.emitted.append(value)
      return .none
    }
  }
}

struct ThrottleTrailingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var emitted: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case trigger(Int)
    case _emitted(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .trigger(let value):
      return EffectTask.send(._emitted(value))
        .throttle("throttle-trailing", for: .milliseconds(80), leading: false, trailing: true)
    case ._emitted(let value):
      state.emitted.append(value)
      return .none
    }
  }
}

struct ThrottleLeadingTrailingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var emitted: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case trigger(Int)
    case _emitted(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .trigger(let value):
      return EffectTask.send(._emitted(value))
        .throttle(
          "throttle-leading-trailing", for: .milliseconds(80), leading: true, trailing: true)
    case ._emitted(let value):
      state.emitted.append(value)
      return .none
    }
  }
}

struct SequentialMergeFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var received: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case _first
    case _second
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .merge(
        .concatenate(
          .run { send, _ in
            await send(._first)
          },
          .send(._second)
        )
      )
    case ._first:
      state.received.append("first")
      return .none
    case ._second:
      state.received.append("second")
      return .none
    }
  }
}

struct AnimationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var values: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case animate(Int)
    case animateRun(Int)
    case _animated(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .animate(let value):
      return EffectTask.send(._animated(value))
        .animation(.easeInOut)

    case .animateRun(let value):
      return EffectTask.run { send in
        await send(._animated(value))
      }
      .animation(.spring())

    case ._animated(let value):
      state.values.append(value)
      return .none
    }
  }
}

struct ComposedAnimationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var value = 0
  }

  enum Action: Equatable, Sendable {
    case trigger(Int)
    case _result(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .trigger(let value):
      return EffectTask.send(._result(value))
        .debounce("animation-debounce", for: .milliseconds(30))
        .animation(.easeInOut)
    case ._result(let value):
      state.value = value
      return .none
    }
  }
}

struct CombinatorCompositionFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var debounced: [Int] = []
    var throttled: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case start(Int)
    case _debounced(Int)
    case _throttled(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let value):
      return .merge(
        EffectTask.send(._debounced(value))
          .debounce("compose-debounce", for: .milliseconds(50)),
        EffectTask.send(._throttled(value))
          .throttle("compose-throttle", for: .milliseconds(50))
      )
    case ._debounced(let value):
      state.debounced.append(value)
      return .none
    case ._throttled(let value):
      state.throttled.append(value)
      return .none
    }
  }
}

actor DeinitCancellationProbe {
  private(set) var started = 0
  private(set) var cancelled = 0
  private(set) var completed = 0

  func markStarted() {
    started += 1
  }

  func markCancelled() {
    cancelled += 1
  }

  func markCompleted() {
    completed += 1
  }
}

actor RunStartGateRaceProbe {
  private(set) var started = 0

  func markStarted() {
    started += 1
  }
}

struct RunStartGateRaceFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var requested = false
  }

  enum Action: Equatable, Sendable {
    case start
  }

  let probe: RunStartGateRaceProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      state.requested = true
      return .run { _, _ in
        await probe.markStarted()
      }
      .cancellable("start-gate-race")
    }
  }
}

struct ChildScopedReducer: Reducer {
  struct State: Equatable, Sendable {
    var value = 0
  }

  enum Action: Equatable, Sendable {
    case increment
    case _report
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .increment:
      state.value += 1
      return .send(._report)
    case ._report:
      return .none
    }
  }
}

struct ComposedReducerFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var events: [String] = []
    var child = ChildScopedReducer.State()
  }

  enum Action: Equatable, Sendable {
    case start
    case child(ChildScopedReducer.Action)

    static let childCasePath = CasePath<Self, ChildScopedReducer.Action>(
      embed: Action.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    CombineReducers {
      Reduce<State, Action> { state, action in
        switch action {
        case .start:
          state.events.append("start")
          return .send(.child(.increment))
        case .child(.increment):
          state.events.append("parent saw child increment")
          return .none
        case .child(._report):
          state.events.append("parent saw child report")
          return .none
        }
      }

      Scope(
        state: \.child,
        action: Action.childCasePath,
        reducer: ChildScopedReducer()
      )
    }
    .reduce(into: &state, action: action)
  }
}

struct BuilderCompositionFeature {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case run
  }

  static func append(_ label: String) -> Reduce<State, Action> {
    Reduce { state, action in
      guard case .run = action else { return .none }
      state.log.append(label)
      return .none
    }
  }

  @ReducerBuilder<State, Action>
  static func emptyBuilder() -> some Reducer<State, Action> {}

  @ReducerBuilder<State, Action>
  static func optionalBuilder(includeReducer: Bool) -> some Reducer<State, Action> {
    if includeReducer {
      append("optional")
    }
  }

  @ReducerBuilder<State, Action>
  static func eitherBuilder(chooseFirst: Bool) -> some Reducer<State, Action> {
    if chooseFirst {
      append("first")
    } else {
      append("second")
    }
  }

  @ReducerBuilder<State, Action>
  static func arrayBuilder(labels: [String]) -> some Reducer<State, Action> {
    for label in labels {
      append(label)
    }
  }

  @ReducerBuilder<State, Action>
  static func straightLineBuilder() -> some Reducer<State, Action> {
    append("first")
    append("second")
  }
}

struct ValidatedPhaseReducer: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loading
      case loaded
    }

    var phase: Phase = .idle
  }

  enum Action: Equatable, Sendable {
    case noop
    case load
    case finish
  }

  static let graph: PhaseTransitionGraph<State.Phase> = [
    .idle: [.loading],
    .loading: [.loaded],
    .loaded: [.loading],
  ]

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    Reduce<State, Action> { state, action in
      switch action {
      case .noop:
        return .none
      case .load:
        state.phase = .loading
        return .none
      case .finish:
        state.phase = .loaded
        return .none
      }
    }
    .validatePhaseTransitions(tracking: \.phase, through: Self.graph)
    .reduce(into: &state, action: action)
  }
}

struct PhaseMapHarness: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    var phase: Phase = .idle
    var values: [Int] = []
    var errorMessage: String?
  }

  enum Action: Equatable, Sendable {
    case load
    case loaded([Int])
    case failed(String)
    case replaceAndDismiss([Int])
    case maybeRecover(Bool)
    case noop
  }

  static let loadedCasePath = CasePath<Action, [Int]>(
    embed: Action.loaded,
    extract: { action in
      guard case .loaded(let payload) = action else { return nil }
      return payload
    }
  )

  static let failedCasePath = CasePath<Action, String>(
    embed: Action.failed,
    extract: { action in
      guard case .failed(let payload) = action else { return nil }
      return payload
    }
  )

  static let maybeRecoverCasePath = CasePath<Action, Bool>(
    embed: Action.maybeRecover,
    extract: { action in
      guard case .maybeRecover(let payload) = action else { return nil }
      return payload
    }
  )

  static let replaceAndDismissCasePath = CasePath<Action, [Int]>(
    embed: Action.replaceAndDismiss,
    extract: { action in
      guard case .replaceAndDismiss(let payload) = action else { return nil }
      return payload
    }
  )

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(Self.loadedCasePath, to: .loaded)
        On(Self.failedCasePath, to: .failed)
      }
      From(.loaded) {
        On(.load, to: .loading)
      }
      From(.failed) {
        On(Self.replaceAndDismissCasePath, targets: [.idle, .loaded]) { state, _ in
          state.values.isEmpty ? .idle : .loaded
        }
        On(Self.maybeRecoverCasePath, targets: [.loaded]) { _, shouldRecover in
          shouldRecover ? .loaded : nil
        }
      }
    }
  }

  static var phaseGraph: PhaseTransitionGraph<State.Phase> {
    phaseMap.derivedGraph
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return CombineReducers {
      Reduce<State, Action> { state, action in
        switch action {
        case .load:
          state.errorMessage = nil
          return .none
        case .loaded(let values):
          state.values = values
          state.errorMessage = nil
          return .none
        case .failed(let message):
          state.errorMessage = message
          return .none
        case .replaceAndDismiss(let values):
          state.values = values
          state.errorMessage = nil
          return .none
        case .maybeRecover, .noop:
          return .none
        }
      }
    }
    .phaseMap(map)
    .reduce(into: &state, action: action)
  }
}

struct PhaseMapOrderingHarness: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case first
      case second
    }

    var phase: Phase = .idle
  }

  enum Action: Equatable, Sendable {
    case advance
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(.advance, to: .first)
        On(where: { action in action == .advance }, targets: [.second]) { _, _ in .second }
      }
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce<State, Action> { _, _ in .none }
      .phaseMap(map)
      .reduce(into: &state, action: action)
  }
}

struct PhaseMapDirectMutationHarness: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loading
      case loaded
    }

    var phase: Phase = .idle
    var values: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case load
    case loaded([Int])
  }

  static let loadedCasePath = CasePath<Action, [Int]>(
    embed: Action.loaded,
    extract: { action in
      guard case .loaded(let payload) = action else { return nil }
      return payload
    }
  )

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(Self.loadedCasePath, to: .loaded)
      }
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce<State, Action> { state, action in
      switch action {
      case .load:
        state.phase = .loaded
        return .none
      case .loaded(let values):
        state.phase = .idle
        state.values = values
        return .none
      }
    }
    .phaseMap(map)
    .reduce(into: &state, action: action)
  }
}

struct PhaseMapInvalidTargetHarness: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loaded
      case failed
      case unexpected
    }

    var phase: Phase = .failed
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case attemptRecover(Bool)
  }

  static let attemptRecoverCasePath = CasePath<Action, Bool>(
    embed: Action.attemptRecover,
    extract: { action in
      guard case .attemptRecover(let payload) = action else { return nil }
      return payload
    }
  )

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.failed) {
        On(Self.attemptRecoverCasePath, targets: [.idle, .loaded]) { _, shouldRecover in
          shouldRecover ? .unexpected : nil
        }
      }
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce<State, Action> { state, action in
      switch action {
      case .attemptRecover(let shouldRecover):
        state.log.append(shouldRecover ? "recover" : "skip")
        return .none
      }
    }
    .phaseMap(map)
    .reduce(into: &state, action: action)
  }
}

struct PhaseMapPredicateHarness: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Equatable, Hashable, Sendable {
      case idle
      case loading
      case loaded
    }

    var phase: Phase = .idle
    var shouldAdvance = false
  }

  enum Action: Equatable, Sendable {
    case start
    case configure(Bool)
    case refresh
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(where: { $0 == .start }, to: .loading)
      }
      From(.loading) {
        On(where: { $0 == .configure(true) }, targets: [.loaded]) { _, _ in .loaded }
        On(where: { $0 == .configure(false) }, targets: [.loaded]) { _, _ in nil }
        On(where: { $0 == .refresh }, targets: [.loading]) { _, _ in .loading }
      }
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce<State, Action> { state, action in
      switch action {
      case .configure(let value):
        state.shouldAdvance = value
        return .none
      case .start, .refresh:
        return .none
      }
    }
    .phaseMap(map)
    .reduce(into: &state, action: action)
  }
}

struct DeinitCancellationFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    var started = false
  }

  enum Action: Equatable, Sendable {
    case start
    case _finished
  }

  let probe: DeinitCancellationProbe

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      state.started = true
      return .run { send in
        await probe.markStarted()
        do {
          try await Task.sleep(for: .seconds(5))
          await probe.markCompleted()
          await send(._finished)
        } catch {
          await probe.markCancelled()
        }
      }
      .cancellable("deinit-effect")
    case ._finished:
      return .none
    }
  }
}
