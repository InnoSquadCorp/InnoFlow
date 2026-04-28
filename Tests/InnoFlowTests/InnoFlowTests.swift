// MARK: - InnoFlowTests.swift
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

private struct ProjectionObserverSnapshot: Equatable {
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
        .run { send in
          try? await Task.sleep(for: .milliseconds(30))
          await send(._emitted("slow"))
        },
        .run { send in
          try? await Task.sleep(for: .milliseconds(5))
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
          try await Task.sleep(for: .milliseconds(200))
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
  let cancellationID: EffectID
  let includesAsyncTail: Bool

  init(
    chainDepth: Int,
    cancellationID: EffectID = "deep-lazy-map-stress",
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

// MARK: - EffectTask Tests

@Suite("EffectTask Tests", .serialized)
@MainActor
struct EffectTaskTests {

  @Test("EffectID supports StaticString literals")
  func effectIDStaticStringLiteral() {
    let first: EffectID = "load-user"
    let second = EffectID("load-user")

    #expect(first == second)
    #expect(first.hashValue == second.hashValue)
    #expect(String(describing: first.rawValue) == "load-user")
  }

  @Test("EffectTask.none does not emit follow-up actions")
  func effectNone() async {
    let store = TestStore(reducer: CounterFeature(), initialState: .init())

    await store.send(.increment) {
      $0.count = 1
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.send emits a follow-up action")
  func effectSend() async {
    let store = TestStore(reducer: ImmediateSendFeature(), initialState: .init())

    await store.send(.trigger)

    await store.receive(._logged("event")) {
      $0.logs = ["event"]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.cancellable keeps only the latest in-flight effect")
  func effectCancellable() async {
    let store = TestStore(reducer: CancellableFeature(), initialState: .init())

    await store.send(.start(1)) {
      $0.requested = 1
    }
    await store.send(.start(2)) {
      $0.requested = 2
    }

    await store.receive(._completed(2)) {
      $0.completed = [2]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.debounce keeps only the latest trigger")
  func effectDebounce() async {
    let clock = ManualTestClock()
    let store = TestStore(reducer: DebounceFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))

    for _ in 0..<200 {
      if await clock.sleeperCount == 1 {
        break
      }
      await Task.yield()
    }
    await clock.advance(by: .milliseconds(60))

    await store.receive(._emitted(2)) {
      $0.emitted = [2]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.throttle uses leading-only semantics")
  func effectThrottleLeadingOnly() async {
    let clock = ManualTestClock()
    let store = TestStore(reducer: ThrottleFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))

    await store.receive(._emitted(1)) {
      $0.emitted = [1]
    }
    await store.assertNoMoreActions()

    await Task.yield()
    await clock.advance(by: .milliseconds(160))
    await store.send(.trigger(3))
    await store.receive(._emitted(3)) {
      $0.emitted = [1, 3]
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.throttle trailing-only executes latest at window end")
  func effectThrottleTrailingOnly() async {
    let clock = ManualTestClock()
    let store = TestStore(reducer: ThrottleTrailingFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))
    await Task.yield()
    await clock.advance(by: .milliseconds(80))

    await store.receive(._emitted(2)) {
      $0.emitted = [2]
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.throttle leading+trailing executes both when window has extra event")
  func effectThrottleLeadingAndTrailing() async {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: ThrottleLeadingTrailingFeature(), initialState: .init(), clock: clock)

    await store.send(.trigger(1))
    await store.send(.trigger(2))

    await store.receive(._emitted(1)) {
      $0.emitted = [1]
    }
    await Task.yield()
    await clock.advance(by: .milliseconds(80))
    await store.receive(._emitted(2)) {
      $0.emitted = [1, 2]
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.animation executes nested send and run effects")
  func effectAnimationExecutes() async {
    let store = TestStore(reducer: AnimationFeature(), initialState: .init())

    await store.send(.animate(1))
    await store.receive(._animated(1)) {
      $0.values = [1]
    }

    await store.send(.animateRun(2))
    await store.receive(._animated(2)) {
      $0.values = [1, 2]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.animation composes with debounce")
  func effectAnimationComposedWithDebounce() async {
    let store = TestStore(reducer: ComposedAnimationFeature(), initialState: .init())

    await store.send(.trigger(1))
    await store.receive(._result(1)) {
      $0.value = 1
    }
    await store.assertNoMoreActions()
  }

  @Test("EffectTask.concatenate preserves declared send order")
  func effectConcatenatePreservesSendOrder() async {
    let store = TestStore(
      reducer: QueueDispatchFeature(probe: ReducerDepthProbe()),
      initialState: .init()
    )

    await store.send(.start) {
      $0.logs = ["start"]
    }

    await store.receive(.first) {
      $0.logs = ["start", "first"]
    }
    await store.receive(.second) {
      $0.logs = ["start", "first", "second"]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.run emits follow-up actions after the async boundary")
  func effectRunEmitsAfterAsyncBoundary() async {
    let store = TestStore(
      reducer: QueueDispatchFeature(probe: ReducerDepthProbe()),
      initialState: .init()
    )

    await store.send(.loadAsync) {
      $0.logs = ["loadAsync"]
    }

    await store.receive(._loadedAsync) {
      $0.logs = ["loadAsync", "loadedAsync"]
    }

    await store.assertNoMoreActions()
  }

  @Test("EffectTask.merge emits in child completion order rather than declaration order")
  func effectMergeUsesCompletionOrder() async {
    let store = TestStore(reducer: MergeOrderingFeature(), initialState: .init())

    await store.send(.start)

    await store.receive(._emitted("fast")) {
      $0.emitted = ["fast"]
    }
    await store.receive(._emitted("slow")) {
      $0.emitted = ["fast", "slow"]
    }

    await store.assertNoMoreActions()
  }

  @Test("Parent-child orchestration can be modeled as ordered child actions")
  func parentChildOrchestration() async {
    let store = TestStore(reducer: ParentChildOrchestrationFeature(), initialState: .init())

    await store.send(.refresh) {
      $0.isRefreshing = true
      $0.log = ["refresh"]
    }

    await store.receive(.child(.profileLoaded)) {
      $0.profileLoaded = true
      $0.log = ["refresh", "profile"]
    }
    await store.receive(.child(.permissionsLoaded)) {
      $0.permissionsLoaded = true
      $0.log = ["refresh", "profile", "permissions"]
    }
    await store.receive(._finished) {
      $0.isRefreshing = false
      $0.log = ["refresh", "profile", "permissions", "finished"]
    }

    await store.assertNoMoreActions()
  }

  @Test("Long-running orchestration can mix immediate and awaited progress actions")
  func longRunningOrchestration() async {
    let store = TestStore(reducer: LongRunningOrchestrationFeature(), initialState: .init())

    await store.send(.start)
    await store.receive(._progress(0)) {
      $0.progress = [0]
    }
    await store.receive(._progress(50)) {
      $0.progress = [0, 50]
    }
    await store.receive(._finished) {
      $0.finished = true
    }

    await store.assertNoMoreActions()
  }

  @Test(
    "EffectTask.cancellable latest-wins semantics hold across random trigger streams",
    arguments: Array(0..<50)
  )
  func effectCancellableLatestWinsProperty(seed: Int) async throws {
    let store = TestStore(reducer: CancellableFeature(), initialState: .init())
    var rng = SeededGenerator(seed: UInt64(seed + 1))
    let count = rng.nextInt(upperBound: 6) + 2
    let values = (0..<count).map { _ in rng.nextInt(upperBound: 10_000) }

    for (index, value) in values.enumerated() {
      await store.send(.start(value)) {
        $0.requested = index + 1
      }
    }

    let winner = try #require(values.last)
    await store.receive(._completed(winner)) {
      $0.completed = [winner]
    }
    await store.assertNoMoreActions()
  }

  @Test(
    "EffectTask.debounce latest-wins semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectDebounceLatestWinsProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 101))
    let expected = expectedDebounceOutputs(for: steps, intervalMilliseconds: 60)
    let actual = await runTimingScenario(
      reducer: DebounceFeature(),
      steps: steps,
      trigger: DebounceFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }

  @Test(
    "EffectTask.throttle leading-only semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectThrottleLeadingOnlyProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 201))
    let expected = expectedThrottleOutputs(
      for: steps,
      intervalMilliseconds: 80,
      leading: true,
      trailing: false
    )
    let actual = await runTimingScenario(
      reducer: ThrottleFeature(),
      steps: steps,
      trigger: ThrottleFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }

  @Test(
    "EffectTask.throttle trailing-only semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectThrottleTrailingOnlyProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 301))
    let expected = expectedThrottleOutputs(
      for: steps,
      intervalMilliseconds: 80,
      leading: false,
      trailing: true
    )
    let actual = await runTimingScenario(
      reducer: ThrottleTrailingFeature(),
      steps: steps,
      trigger: ThrottleTrailingFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }

  @Test(
    "EffectTask.throttle leading+trailing semantics hold across random timing streams",
    arguments: Array(0..<50)
  )
  func effectThrottleLeadingTrailingProperty(seed: Int) async {
    let steps = makeTimingScenario(seed: UInt64(seed + 401))
    let expected = expectedThrottleOutputs(
      for: steps,
      intervalMilliseconds: 80,
      leading: true,
      trailing: true
    )
    let actual = await runTimingScenario(
      reducer: ThrottleLeadingTrailingFeature(),
      steps: steps,
      trigger: ThrottleLeadingTrailingFeature.Action.trigger,
      emitted: \.emitted,
      expectedCount: expected.count
    )

    #expect(actual == expected)
  }
}

@Suite("Phase Transition Graph Tests")
@MainActor
struct PhaseTransitionGraphTests {
  @Test("Graph exposes legal successors for a phase")
  func successors() {
    let graph = PhaseDrivenFeature.graph

    #expect(graph.allows(from: .idle, to: .loading))
    #expect(!graph.allows(from: .idle, to: .loaded))
    #expect(graph.successors(from: .loading) == [.loaded, .failed])
  }

  @Test("Graph supports linear declaration for simple workflows")
  func linearGraph() {
    let graph = PhaseTransitionGraph<PhaseDrivenFeature.Phase>.linear(.idle, .loading, .loaded)

    #expect(graph.allows(from: .idle, to: .loading))
    #expect(graph.allows(from: .loading, to: .loaded))
    #expect(!graph.allows(from: .loaded, to: .failed))
    #expect(
      graph.validate(
        allPhases: [.idle, .loading, .loaded],
        terminalPhases: [.loaded]
      ).isEmpty
    )
  }

  @Test("Graph supports dictionary literal declaration")
  func dictionaryLiteralGraph() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .loading: [.loaded, .failed],
    ]

    #expect(graph.allows(from: .idle, to: .loading))
    #expect(graph.successors(from: .loading) == [.loaded, .failed])
  }

  @Test("TestStore phase helper validates legal reducer transitions")
  func testStorePhaseTracking() async {
    let store = TestStore(reducer: PhaseDrivenFeature())

    await store.send(.load, tracking: \.phase, through: PhaseDrivenFeature.graph) {
      $0.phase = .loading
    }

    await store.receive(._loaded("done"), tracking: \.phase, through: PhaseDrivenFeature.graph) {
      $0.phase = .loaded
      $0.value = "done"
    }

    await store.assertNoMoreActions()
  }

  @Test("Graph validation reports unreachable phases and non-terminal dead ends")
  func graphValidationFindsStructuralIssues() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .loading: [.loaded],
    ]

    let issues = graph.validate(
      allPhases: [.idle, .loading, .loaded, .failed],
      root: .idle
    )

    #expect(issues.contains(.unreachablePhase(.failed)))
    #expect(issues.contains(.nonTerminalDeadEnd(.loaded)))
  }

  @Test("Graph validation reports unknown successors and invalid terminal transitions")
  func graphValidationReportsUnknownSuccessorsAndTerminalViolations() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .failed: [.loading],
    ]

    let issues = graph.validate(
      allPhases: [.idle, .loading],
      root: .idle,
      terminalPhases: [.idle]
    )

    #expect(issues.contains(.unknownSuccessor(from: .failed, to: .loading)))
    #expect(issues.contains(.terminalHasOutgoingEdges(.idle)))
  }

  @Test("Graph validation report includes root declaration and reachability context")
  func graphValidationReportIncludesReachabilityContext() {
    let graph: PhaseTransitionGraph<PhaseDrivenFeature.Phase> = [
      .idle: [.loading],
      .loading: [.loaded],
    ]

    let report = graph.validationReport(
      allPhases: [.idle, .loading, .loaded],
      root: .failed,
      terminalPhases: [.loaded]
    )

    #expect(report.issues.contains(.rootNotDeclared(.failed)))
    #expect(report.issues.contains(.unreachablePhase(.idle)))
    #expect(report.issues.contains(.unreachablePhase(.loading)))
    #expect(report.issues.contains(.unreachablePhase(.loaded)))
    #expect(report.reachable == [.failed])
    #expect(report.unreachable == [.idle, .loading, .loaded])
    #expect(report.declaredPhases == [.idle, .loading, .loaded])
    #expect(report.terminalPhases == [.loaded])
  }

  @Test("assertValidGraph passes clean graphs through the testing helper")
  func assertValidGraphHelper() {
    assertValidGraph(
      PhaseDrivenFeature.graph,
      allPhases: [.idle, .loading, .loaded, .failed],
      root: .idle,
      terminalPhases: [.loaded]
    )
  }
}

@Suite("Compile Contract Tests")
struct CompileContractTests {

  @Test("EffectID rejects dynamic String construction at compile time")
  func effectIDRejectsDynamicStringConstruction() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      let dynamic = String("dynamic-id")
      let _ = EffectID(dynamic)
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("error")
        || diagnostics.localizedCaseInsensitiveContains("failed")
    )
    #expect(
      diagnostics.contains("EffectID")
        || diagnostics.contains("StaticString")
        || diagnostics.contains("String")
    )
  }

  @Test("Store.binding rejects non-bindable key paths at compile time")
  func bindingRejectsNonBindableKeyPathAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct NonBindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              var count = 0
              init() {}
          }

          enum Action: Sendable {
              case setCount(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: NonBindableFeature(), initialState: .init())
          _ = store.binding(\\.count, send: { .setCount($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("error")
        || diagnostics.localizedCaseInsensitiveContains("failed")
    )
    #expect(!diagnostics.localizedCaseInsensitiveContains("no such module 'InnoFlow'"))
    #expect(
      diagnostics.localizedCaseInsensitiveContains("binding")
        || diagnostics.contains("BindableProperty")
        || diagnostics.contains("KeyPath")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.contains("CompileContract.swift")
        || diagnostics.contains("store.binding")
        || diagnostics.contains("\\.count")
        || diagnostics.contains("NonBindableFeature")
        || diagnostics.localizedCaseInsensitiveContains("generic parameter")
    )
  }

  @Test("ScopedStore.binding rejects non-bindable child key paths at compile time")
  func scopedBindingRejectsNonBindableKeyPathAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              var count = 0
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setCount(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.count, send: { .setCount($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("binding")
        || diagnostics.contains("BindableProperty")
        || diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.contains("\\.count")
        || diagnostics.contains("scoped")
    )
  }

  @Test("Store.binding accepts projected key paths from @BindableField authoring")
  func bindingAcceptsBindableFieldProjectedKeyPath() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, send: { .setStep($0) })
      }
      """

    let result = try typecheckSource(
      source,
      moduleDirectory: moduleDirectory
    )

    #expect(
      result.status == 0,
      "expected @BindableField projected key path to typecheck, got: \(result.normalizedOutput)")
  }

  @Test("Store.binding rejects unlabeled trailing-closure calls with explicit label guidance")
  func bindingRejectsUnlabeledTrailingClosureAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step) { .setStep($0) }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(diagnostics.localizedCaseInsensitiveContains("ambiguous use of 'binding'"))
    #expect(diagnostics.contains("binding(_:send:)"))
    #expect(diagnostics.contains("binding(_:to:)"))
  }

  @Test("Store.binding rejects parenthesized unlabeled calls with explicit label guidance")
  func bindingRejectsParenthesizedUnlabeledCallAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct BindableFeature: Reducer {
          struct State: Sendable, DefaultInitializable {
              @BindableField var step = 1
              init() {}
          }

          enum Action: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: BindableFeature(), initialState: .init())
          _ = store.binding(\\.$step, { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(diagnostics.contains("no exact matches in call to instance method 'binding'"))
    #expect(diagnostics.contains("incorrect labels for candidate"))
    #expect(diagnostics.contains("expected: '(_:send:)'"))
    #expect(diagnostics.contains("expected: '(_:to:)'"))
  }

  @Test("ScopedStore.binding rejects unlabeled trailing-closure calls with explicit label guidance")
  func scopedBindingRejectsUnlabeledTrailingClosureAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              @BindableField var step = 1
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.$step) { .setStep($0) }
      }
      """

      let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(diagnostics.localizedCaseInsensitiveContains("ambiguous use of 'binding'"))
    #expect(diagnostics.contains("binding(_:send:)"))
    #expect(diagnostics.contains("binding(_:to:)"))
  }

  @Test("ScopedStore.binding rejects parenthesized unlabeled calls with explicit label guidance")
  func scopedBindingRejectsParenthesizedUnlabeledCallAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ParentFeature: Reducer {
          struct Child: Equatable, Sendable {
              @BindableField var step = 1
          }

          struct State: Sendable, DefaultInitializable {
              var child = Child()
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)

              static let childCasePath = CasePath<Self, ChildAction>(
                  embed: Action.child,
                  extract: { action in
                      guard case .child(let childAction) = action else { return nil }
                      return childAction
                  }
              )
          }

          enum ChildAction: Sendable {
              case setStep(Int)
          }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
              .none
          }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentFeature(), initialState: .init())
          let scoped = store.scope(state: \\.child, action: ParentFeature.Action.childCasePath)
          _ = scoped.binding(\\.$step, { .setStep($0) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(diagnostics.contains("no exact matches in call to instance method 'binding'"))
    #expect(diagnostics.contains("incorrect labels for candidate"))
    #expect(diagnostics.contains("expected: '(_:send:)'"))
    #expect(diagnostics.contains("expected: '(_:to:)'"))
  }

  @Test("Scope/IfLet/IfCaseLet reject public closure-based action lifting at compile time")
  func reducerCompositionRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct ChildReducer: Reducer {
          struct State: Equatable, Sendable {}
          enum Action: Sendable { case start }
          func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
      }

      struct ParentReducer: Reducer {
          enum Screen: Equatable, Sendable {
              case child(ChildReducer.State)
              case idle
          }

          struct State: Equatable, Sendable {
              var child = ChildReducer.State()
              var optionalChild: ChildReducer.State? = .init()
              var screen: Screen = .child(.init())
          }

          enum Action: Sendable {
              case child(ChildReducer.Action)
          }

          static let childState = CasePath<State.Screen, ChildReducer.State>(
              embed: State.Screen.child,
              extract: { screen in
                  guard case .child(let state) = screen else { return nil }
                  return state
              }
          )

          var body: some Reducer<State, Action> {
              CombineReducers {
                  Scope(
                      state: \\.child,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )

                  IfLet(
                      state: \\.optionalChild,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )

                  IfCaseLet(
                      state: Self.childState,
                      extractAction: { action in
                          guard case .child(let childAction) = action else { return nil }
                          return childAction
                      },
                      embedAction: Action.child,
                      reducer: ChildReducer()
                  )
              }
          }
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("extra arguments")
        || diagnostics.localizedCaseInsensitiveContains("incorrect argument labels")
        || diagnostics.contains("extractAction")
        || diagnostics.contains("embedAction")
    )
  }

  @Test("Store.scope rejects public closure-based action lifting at compile time")
  func storeScopeRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let moduleDirectory = try findBuiltInnoFlowModuleDirectory(in: packageRoot)

    let source = """
      import InnoFlow

      struct Todo: Equatable, Identifiable, Sendable {
          let id: UUID
          var title: String
      }

      struct ParentReducer: Reducer {
          struct Child: Equatable, Sendable {}

          struct State: Equatable, Sendable, DefaultInitializable {
              var child = Child()
              var todos = [Todo(id: UUID(), title: "One")]
              init() {}
          }

          enum Action: Sendable {
              case child(ChildAction)
              case todo(id: UUID, action: TodoAction)
          }

          enum ChildAction: Sendable { case start }
          enum TodoAction: Sendable { case rename(String) }

          func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
      }

      @MainActor
      func compileContract() {
          let store = Store(reducer: ParentReducer(), initialState: .init())
          _ = store.scope(state: \\.child, action: { ParentReducer.Action.child($0) })
          _ = store.scope(collection: \\.todos, action: { id, action in ParentReducer.Action.todo(id: id, action: action) })
      }
      """

    let result = try typecheckSource(source, moduleDirectory: moduleDirectory)

    #expect(result.status != 0)
    let diagnostics = result.normalizedOutput
    #expect(!diagnostics.isEmpty)
    #expect(
      diagnostics.localizedCaseInsensitiveContains("no exact matches")
        || diagnostics.localizedCaseInsensitiveContains("cannot convert")
        || diagnostics.contains("scope")
        || diagnostics.contains("action:")
    )
  }

  @Test("TestStore.scope keeps only CasePath-based public scoping APIs")
  func testStoreScopeRejectsClosureActionLiftingAtCompileTime() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = packageRoot.appendingPathComponent("Sources/InnoFlowTesting/TestStore.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    let forbiddenSignatures = [
      """
      public func scope<ChildState: Equatable, ChildAction>(
        state: WritableKeyPath<R.State, ChildState>,
        extractAction:
      """,
      """
      public func scope<CollectionState, ChildAction>(
        collection: WritableKeyPath<R.State, CollectionState>,
        id: CollectionState.Element.ID,
        extractAction:
      """,
    ]

    for signature in forbiddenSignatures {
      #expect(source.contains(signature) == false)
    }
  }
}

// MARK: - Store Tests

@Suite("Store Tests", .serialized)
@MainActor
struct StoreTests {

  @Test("Store initializes with explicit state")
  func storeInitialization() {
    let store = Store(reducer: CounterFeature(), initialState: .init(count: 10))
    #expect(store.count == 10)
  }

  @Test("Store processes synchronous actions")
  func storeSyncActions() {
    let store = Store(reducer: CounterFeature(), initialState: .init(count: 0))

    store.send(.increment)
    store.send(.increment)
    store.send(.decrement)

    #expect(store.count == 1)
  }

  @Test("ScopedStore reflects child state and forwards actions")
  func scopedStoreProjectionAndForwarding() {
    let store = Store(reducer: ScopedCounterFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child,
      action: ScopedCounterFeature.Action.selfCasePath
    )

    #expect(scoped.count == 0)
    scoped.send(.childIncrement)
    #expect(scoped.count == 1)
    #expect(store.state.child.count == 1)
  }

  @Test("Store.binding reads and writes bindable field")
  func bindingPositivePath() {
    let store = Store(reducer: BindingFeature(), initialState: .init())
    let binding = store.binding(\.$step, send: { .setStep($0) })

    #expect(binding.wrappedValue == 1)
    binding.wrappedValue = 5
    #expect(store.step == 5)
  }

  @Test("ScopedStore.binding reads and writes bindable child field")
  func scopedBindingPositivePath() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child,
      action: ScopedBindableChildFeature.Action.childCasePath
    )
    let binding = scoped.binding(\.$step, send: { .setStep($0) })

    #expect(scoped.step == 1)
    #expect(binding.wrappedValue == 1)

    binding.wrappedValue = 4

    #expect(scoped.step == 4)
    #expect(store.state.child.step == 4)
  }

  @Test("Plain dependency bundles inject reducer-side services without a bridge target")
  @MainActor
  func dependencyBundleFeatureLoadsService() async {
    let store = TestStore(
      reducer: DependencyBundleFeature(service: DependencyBundleService(value: "from-bundle"))
    )

    await store.send(.load)
    await store.receive(._loaded("from-bundle")) {
      $0.output = "from-bundle"
      $0.log = ["loaded from-bundle"]
    }
  }

  @Test("Store.preview creates preview stores with explicit and default state")
  @MainActor
  func storePreviewHelpers() {
    let explicit: Store<CounterFeature> = .preview(
      reducer: CounterFeature(),
      initialState: .init(count: 42)
    )
    let defaulted: Store<CounterFeature> = .preview(reducer: CounterFeature())

    #expect(explicit.count == 42)
    #expect(defaulted.count == 0)
  }

  @Test("Store collection scoping preserves order and routes child actions by id")
  func collectionScopingPreservesOrderAndRoutesActions() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    #expect(scopedTodos.map(\.title) == ["One", "Two", "Three"])
    #expect(scopedTodos.map(\.id) == store.state.todos.map(\.id))
    #expect(scopedTodos[1].isDone == false)

    let binding = scopedTodos[1].binding(\.$isDone, send: { .setDone($0) })
    binding.wrappedValue = true

    #expect(scopedTodos[1].isDone == true)
    #expect(store.state.todos[0].isDone == false)
    #expect(store.state.todos[1].isDone == true)
    #expect(store.state.todos[2].isDone == false)
  }

  @Test("Store scope(state:action:) accepts CasePath overload")
  func scopeStateCasePathOverload() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)

    #expect(scoped.step == 1)
    scoped.send(.setStep(6))
    #expect(store.state.child.step == 6)
  }

  @Test("ScopedStore ignores unrelated parent mutations when observing child state")
  func scopedStoreIgnoresUnrelatedParentMutations() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scoped.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(scoped.step == 1)
  }

  @Test("ScopedStore ignores repeated unrelated parent mutations when observing child state")
  func scopedStoreIgnoresRepeatedUnrelatedParentMutations() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scoped.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    store.send(.setUnrelated(2))
    store.send(.setUnrelated(3))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(scoped.step == 1)
  }

  @Test("ScopedStore invalidates when child snapshot changes")
  func scopedStoreInvalidatesOnChildMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scoped.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setStep(7)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(scoped.step == 7)
  }

  @Test("Store.select preserves SelectedStore identity across repeated calls")
  func selectedStoreCachingPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(\.child, fileID: #fileID, line: callsiteLine)
    let second = store.select(\.child, fileID: #fileID, line: callsiteLine)

    #expect(first === second)
    #expect(first.step == 1)
  }

  @Test("Store.select(dependingOn:) preserves SelectedStore identity across repeated calls")
  func selectedStoreDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(dependingOn: \.child.title, fileID: #fileID, line: callsiteLine) {
      title in
      title.uppercased()
    }
    let second = store.select(dependingOn: \.child.title, fileID: #fileID, line: callsiteLine) {
      title in
      title.uppercased()
    }

    #expect(first === second)
    #expect(first.value == "CHILD")
  }

  @Test(
    "Store.select(dependingOn:(..., ...)) preserves SelectedStore identity across repeated calls")
  func selectedStoreTwoFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      dependingOn: (\.child.step, \.child.title),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title in
      "\(title)-\(step)"
    }
    let second = store.select(
      dependingOn: (\.child.step, \.child.title),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title in
      "\(title)-\(step)"
    }

    #expect(first === second)
    #expect(first.value == "Child-1")
  }

  @Test("Store.select(dependingOn:(..., ...)) invalidates when either dependency changes")
  func selectedStoreTwoFieldDependingOnInvalidatesForAnyDependencyMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(dependingOn: (\.child.step, \.child.title)) { step, title in
      "\(title)-\(step)"
    }
    let initial = store.projectionObserverStats

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)
    #expect(selected.value == "Child-1")

    store.send(.child(.setStep(4)))
    try? await Task.sleep(for: .milliseconds(20))
    let afterStep = store.projectionObserverStats
    #expect(afterStep.evaluatedObservers == afterUnrelated.evaluatedObservers + 1)
    #expect(afterStep.refreshedObservers == afterUnrelated.refreshedObservers + 1)
    #expect(selected.value == "Child-4")

    store.send(.child(.setTitle("Updated")))
    try? await Task.sleep(for: .milliseconds(20))
    let afterTitle = store.projectionObserverStats
    #expect(afterTitle.evaluatedObservers == afterStep.evaluatedObservers + 1)
    #expect(afterTitle.refreshedObservers == afterStep.refreshedObservers + 1)
    #expect(selected.value == "Updated-4")
  }

  @Test("Store.select(dependingOn:(..., ..., ...)) tracks three explicit dependency slices")
  func selectedStoreThreeFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(
      dependingOn: (\.child.step, \.child.title, \.unrelated)
    ) { step, title, unrelated in
      "\(title)-\(step)-\(unrelated)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setNote("Still ignored")))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 0)
    #expect(selected.value == "Child-1-0")

    store.send(.setUnrelated(2))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 1)
    #expect(selected.value == "Child-1-2")
  }

  @Test(
    "Store.select(dependingOn:(..., ..., ..., ...)) preserves SelectedStore identity across repeated calls"
  )
  func selectedStoreFourFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.select(
      dependingOn: (\.child.step, \.child.title, \.child.note, \.child.priority),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }
    let second = store.select(
      dependingOn: (\.child.step, \.child.title, \.child.note, \.child.priority),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }

    #expect(first === second)
    #expect(first.value == "Child-1-Ready-0")
  }

  @Test(
    "Store.select(dependingOn:(..., ..., ..., ..., ...)) invalidates only for tracked mutations"
  )
  func selectedStoreFiveFieldDependingOnInvalidatesForTrackedMutations() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(
      dependingOn: (\.child.step, \.child.title, \.child.note, \.child.priority, \.child.isEnabled)
    ) { step, title, note, priority, isEnabled in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)"
    }
    let initial = store.projectionObserverStats

    store.send(.setUnrelated(1))
    await waitForProjectionRefreshPass(store, after: initial)
    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)
    #expect(selected.value == "Child-1-Ready-0-true")

    store.send(.child(.setPriority(2)))
    await waitForProjectionObserverStats(store) { stats in
      stats.refreshPassCount > afterUnrelated.refreshPassCount
        && stats.evaluatedObservers >= afterUnrelated.evaluatedObservers + 1
        && stats.refreshedObservers >= afterUnrelated.refreshedObservers + 1
    }
    let afterPriority = store.projectionObserverStats
    #expect(afterPriority.evaluatedObservers == afterUnrelated.evaluatedObservers + 1)
    #expect(afterPriority.refreshedObservers == afterUnrelated.refreshedObservers + 1)
    #expect(selected.value == "Child-1-Ready-2-true")

    store.send(.child(.setEnabled(false)))
    await waitForProjectionObserverStats(store) { stats in
      stats.refreshPassCount > afterPriority.refreshPassCount
        && stats.evaluatedObservers >= afterPriority.evaluatedObservers + 1
        && stats.refreshedObservers >= afterPriority.refreshedObservers + 1
    }
    let afterEnabled = store.projectionObserverStats
    #expect(afterEnabled.evaluatedObservers == afterPriority.evaluatedObservers + 1)
    #expect(afterEnabled.refreshedObservers == afterPriority.refreshedObservers + 1)
    #expect(selected.value == "Child-1-Ready-2-false")
  }

  @Test("Store.select(dependingOn:(..., ..., ..., ..., ..., ...)) tracks six explicit slices")
  func selectedStoreSixFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(
      dependingOn: (
        \.child.step,
        \.child.title,
        \.child.note,
        \.child.priority,
        \.child.isEnabled,
        \.child.version
      )
    ) { step, title, note, priority, isEnabled, version in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)-\(version)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    let initial = store.projectionObserverStats
    store.send(.setUnrelated(2))
    await waitForProjectionRefreshPass(store, after: initial)
    #expect(probe.count == 0)
    #expect(selected.value == "Child-1-Ready-0-true-1")

    store.send(.child(.setVersion(5)))
    await waitUntil {
      probe.count == 1 && selected.value == "Child-1-Ready-0-true-5"
    }
    #expect(probe.count == 1)
    #expect(selected.value == "Child-1-Ready-0-true-5")
  }

  @Test("Store.select ignores parent mutations when the selected value is unchanged")
  func selectedStoreIgnoresUnchangedParentSelection() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(\.child)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.step == 1)
  }

  @Test("Store.select invalidates when the selected value changes")
  func selectedStoreInvalidatesOnSelectedMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(\.child)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.step
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setStep(9)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(selected.step == 9)
  }

  @Test("Store.select(dependingOn:) ignores mutations outside the dependency slice")
  func selectedStoreDependingOnIgnoresMutationsOutsideDependency() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(dependingOn: \.child.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    store.send(.child(.setStep(8)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.value == "CHILD")
  }

  @Test("Store.select(dependingOn:) invalidates when the dependency slice changes")
  func selectedStoreDependingOnInvalidatesOnDependencyMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let selected = store.select(dependingOn: \.child.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setTitle("Updated")))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(selected.value == "UPDATED")
  }

  @Test("ScopedStore.select preserves SelectedStore identity across repeated calls")
  func scopedSelectedStoreCachingPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(\.title, fileID: #fileID, line: callsiteLine)
    let second = scoped.select(\.title, fileID: #fileID, line: callsiteLine)

    #expect(first === second)
    #expect(first.value == "Child")
  }

  @Test("ScopedStore.select(dependingOn:) preserves SelectedStore identity across repeated calls")
  func scopedSelectedStoreDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(dependingOn: \.title, fileID: #fileID, line: callsiteLine) { title in
      title.uppercased()
    }
    let second = scoped.select(dependingOn: \.title, fileID: #fileID, line: callsiteLine) { title in
      title.uppercased()
    }

    #expect(first === second)
    #expect(first.value == "CHILD")
  }

  @Test(
    "ScopedStore.select(dependingOn:(..., ...)) preserves SelectedStore identity across repeated calls"
  )
  func scopedSelectedStoreTwoFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(
      dependingOn: (\.step, \.title),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title in
      "\(title)-\(step)"
    }
    let second = scoped.select(
      dependingOn: (\.step, \.title),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title in
      "\(title)-\(step)"
    }

    #expect(first === second)
    #expect(first.value == "Child-1")
  }

  @Test("ScopedStore.select ignores child mutations when the derived value is unchanged")
  func scopedSelectedStoreIgnoresUnchangedDerivedValue() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(\.title)
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setStep(6)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.value == "Child")
  }

  @Test("ScopedStore.select(dependingOn:) ignores mutations outside the dependency slice")
  func scopedSelectedStoreDependingOnIgnoresMutationsOutsideDependency() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(dependingOn: \.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    store.send(.child(.setStep(6)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(selected.value == "CHILD")
  }

  @Test("ScopedStore.select(dependingOn:) invalidates when the dependency slice changes")
  func scopedSelectedStoreDependingOnInvalidatesOnDependencyMutation() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(dependingOn: \.title) { title in
      title.uppercased()
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setTitle("Ready")))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(selected.value == "READY")
  }

  @Test("ScopedStore.select(dependingOn:(..., ..., ...)) tracks three explicit dependency slices")
  func scopedSelectedStoreThreeFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(dependingOn: (\.step, \.title, \.note)) { step, title, note in
      "\(title)-\(step)-\(note)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.setUnrelated(1))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 0)
    #expect(selected.value == "Child-1-Ready")

    store.send(.child(.setNote("Updated")))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(probe.count == 1)
    #expect(selected.value == "Child-1-Updated")
  }

  @Test(
    "ScopedStore.select(dependingOn:(..., ..., ..., ...)) preserves SelectedStore identity across repeated calls"
  )
  func scopedSelectedStoreFourFieldDependingOnPreservesIdentity() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let callsiteLine: UInt = #line
    let first = scoped.select(
      dependingOn: (\.step, \.title, \.note, \.priority),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }
    let second = scoped.select(
      dependingOn: (\.step, \.title, \.note, \.priority),
      fileID: #fileID,
      line: callsiteLine
    ) { step, title, note, priority in
      "\(title)-\(step)-\(note)-\(priority)"
    }

    #expect(first === second)
    #expect(first.value == "Child-1-Ready-0")
  }

  @Test(
    "ScopedStore.select(dependingOn:(..., ..., ..., ..., ...)) ignores parent mutations outside tracked slices"
  )
  func scopedSelectedStoreFiveFieldDependingOnIgnoresNonDependencies() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(
      dependingOn: (\.step, \.title, \.note, \.priority, \.isEnabled)
    ) { step, title, note, priority, isEnabled in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    let initial = store.projectionObserverStats
    store.send(.setUnrelated(1))
    await waitForProjectionRefreshPass(store, after: initial)
    #expect(probe.count == 0)
    #expect(selected.value == "Child-1-Ready-0-true")

    store.send(.child(.setEnabled(false)))
    await waitUntil {
      probe.count == 1 && selected.value == "Child-1-Ready-0-false"
    }
    #expect(probe.count == 1)
    #expect(selected.value == "Child-1-Ready-0-false")
  }

  @Test("ScopedStore.select(dependingOn:(..., ..., ..., ..., ..., ...)) tracks six explicit slices")
  func scopedSelectedStoreSixFieldDependingOnTracksExplicitSlices() async {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    let selected = scoped.select(
      dependingOn: (\.step, \.title, \.note, \.priority, \.isEnabled, \.version)
    ) { step, title, note, priority, isEnabled, version in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)-\(version)"
    }
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = selected.value
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.child(.setNote("Updated")))
    await waitUntil {
      probe.count == 1 && selected.value == "Child-1-Updated-0-true-1"
    }
    #expect(probe.count == 1)
    #expect(selected.value == "Child-1-Updated-0-true-1")

    let afterTrackedMutation = store.projectionObserverStats
    store.send(.setUnrelated(9))
    await waitForProjectionRefreshPass(store, after: afterTrackedMutation)
    #expect(probe.count == 1)
  }

  @Test("Collection-scoped stores preserve identity across repeated calls")
  func collectionScopeCachingPreservesIdentity() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let first = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )
    let second = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )

    #expect(first.count == second.count)
    for index in first.indices {
      #expect(first[index] === second[index])
    }
  }

  @Test("Collection-scoped stores preserve identity across reorder and prune removed ids")
  func collectionScopeCachingTracksElementsByID() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let initial = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )
    let initialByID = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) })

    store.send(.moveLastToFront)
    let reordered = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )

    #expect(reordered.map(\.id) == store.state.todos.map(\.id))
    for scoped in reordered {
      #expect(scoped === initialByID[scoped.id])
    }

    let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    store.send(.appendTodo(id: newID, title: "Four"))
    let appended = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )
    let appendedNewStore = try! #require(appended.first(where: { $0.id == newID }))
    for scoped in appended where scoped.id != newID {
      #expect(scoped === initialByID[scoped.id])
    }
    #expect(!initial.contains(where: { $0 === appendedNewStore }))

    let removedID = reordered[0].id
    store.send(.removeTodo(id: removedID))
    let removed = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )

    #expect(removed.contains(where: { $0.id == removedID }) == false)
    for scoped in removed where scoped.id != newID {
      #expect(scoped === initialByID[scoped.id])
    }
    #expect(removed.first(where: { $0.id == newID }) === appendedNewStore)
  }

  @Test("Store scope(collection:action:) accepts CollectionActionPath overload")
  func scopeCollectionActionPathOverload() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    scopedTodos[1].send(.setDone(true))

    #expect(store.state.todos[0].isDone == false)
    #expect(store.state.todos[1].isDone == true)
    #expect(store.state.todos[2].isDone == false)
  }

  @Test("ForEachReducer ignores unknown collection ids")
  func forEachReducerIgnoresUnknownIDs() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

    store.send(.todo(id: missingID, action: .setDone(true)))

    #expect(store.state.todos.map(\.isDone) == [false, false, false])
  }

  @Test("IfLet lifts child actions and effects while optional state is present")
  func ifLetScopesOptionalChildState() {
    let store = Store(reducer: IfLetFeature(), initialState: .init())

    store.send(.child(.increment))

    #expect(store.state.child?.count == 1)
    #expect(store.state.log == ["optional-finished"])

    store.send(.dismiss)
    #expect(store.state.child == nil)

    store.send(.present)
    #expect(store.state.child == .init())
  }

  @Test("IfCaseLet lifts child actions and effects while the parent enum case matches")
  func ifCaseLetScopesEnumChildState() {
    let store = Store(reducer: IfCaseLetFeature(), initialState: .init())

    store.send(.activate)
    store.send(.child(.increment))

    #expect(store.state == .child(.init(count: 1, completions: 1)))

    store.send(.deactivate)
    #expect(store.state == .idle)
  }

  @Test("Collection-scoped stores ignore sibling element mutations when observing a row")
  func collectionScopedStoreIgnoresSiblingMutation() async {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scopedTodos[0].isDone
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.todo(id: scopedTodos[1].id, action: .setDone(true)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 0)
    #expect(scopedTodos[0].isDone == false)
    #expect(scopedTodos[1].isDone == true)
  }

  @Test("Collection-scoped stores invalidate when their own element changes")
  func collectionScopedStoreInvalidatesOnOwnMutation() async {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let callsiteLine: UInt = #line
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath,
      fileID: #fileID,
      line: callsiteLine
    )
    let probe = ObservationProbe()

    withObservationTracking(
      {
        _ = scopedTodos[0].isDone
      },
      onChange: {
        probe.recordChange()
      })

    store.send(.todo(id: scopedTodos[0].id, action: .setDone(true)))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(probe.count == 1)
    #expect(scopedTodos[0].isDone == true)
  }

  @Test("ScopedStore stale message formatter includes types, ids, and remediation")
  func scopedStoreFailureMessageFormatter() {
    let elementID = AnyHashable(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    let parentReleased = scopedStoreFailureMessage(
      parentType: ScopedBindableChildFeature.self,
      childType: ScopedBindableChildFeature.Child.self,
      stableID: nil,
      kind: .parentReleased
    )
    #expect(parentReleased.contains("ScopedStore<"))
    #expect(parentReleased.contains("ScopedBindableChildFeature"))
    #expect(parentReleased.contains("Child"))
    #expect(parentReleased.contains("regenerate the scoped store from parent state") == true)

    let collectionRemoved = scopedStoreFailureMessage(
      parentType: ScopedCollectionFeature.self,
      childType: ScopedCollectionFeature.Todo.self,
      stableID: elementID,
      kind: .collectionEntryRemoved
    )
    #expect(collectionRemoved.contains("ScopedCollectionFeature"))
    #expect(collectionRemoved.contains("Todo"))
    #expect(collectionRemoved.contains(String(describing: elementID)) == true)
    #expect(collectionRemoved.contains("source collection entry") == true)

    let identityRequired = scopedStoreFailureMessage(
      parentType: ScopedCollectionFeature.self,
      childType: ScopedCollectionFeature.Todo.self,
      stableID: nil,
      kind: .collectionIdentityRequired
    )
    #expect(identityRequired.contains("Identifiable") == true)
    #expect(identityRequired.contains("store.scope(collection:action:)") == true)
  }

  @Test("ScopedTestStore collection failure helpers include stable ids")
  func scopedTestStoreFailureHelpers() {
    let stableID = AnyHashable(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    #expect(scopedTestStoreFailureContext(stableID: nil) == nil)
    #expect(scopedTestStoreStateMismatchLabel(stableID: nil) == "Scoped state")

    let failureContext = scopedTestStoreFailureContext(stableID: stableID)
    #expect(failureContext?.contains(String(describing: stableID)) == true)
    #expect(
      scopedTestStoreStateMismatchLabel(stableID: stableID).contains("state mismatch") != true)
    #expect(
      scopedTestStoreStateMismatchLabel(stableID: stableID).contains(String(describing: stableID))
        == true)
  }

  @Test("ScopedStore debugDescription reports lifecycle and stable id context")
  func scopedStoreDebugDescription() {
    let store = Store(reducer: ScopedCollectionFeature(), initialState: .init())
    let scopedTodos = store.scope(
      collection: \.todos,
      action: ScopedCollectionFeature.Action.todoActionPath
    )
    let description = scopedTodos[0].debugDescription

    #expect(description.contains("ScopedStore(") == true)
    #expect(description.contains(String(reflecting: ScopedCollectionFeature.self)) == true)
    #expect(description.contains(String(reflecting: ScopedCollectionFeature.Todo.self)) == true)
    #expect(description.contains("parentAlive: true") == true)
    #expect(description.contains("active: true") == true)
    #expect(description.contains(String(describing: scopedTodos[0].id)) == true)
  }

  @Test("Store processes async run effect")
  func storeAsyncEffect() async {
    let store = Store(reducer: AsyncFeature(), initialState: .init())

    store.send(.load)
    #expect(store.isLoading)

    let timeoutClock = ContinuousClock()
    let deadline = timeoutClock.now.advanced(by: .seconds(2))
    while timeoutClock.now < deadline {
      if store.value == "Hello, InnoFlow v2" {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.value == "Hello, InnoFlow v2")
    #expect(store.isLoading == false)
  }

  @Test("Store instrumentation records run lifecycle and emitted actions")
  func storeInstrumentationRunLifecycle() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: InstrumentationFeature(),
      initialState: .init(),
      instrumentation: .init(
        didStartRun: { event in
          probe.record("start:\(event.cancellationID?.rawValue.description ?? "nil")")
        },
        didFinishRun: { event in
          probe.record("finish:\(event.cancellationID?.rawValue.description ?? "nil")")
        },
        didEmitAction: { event in
          probe.record("emit:\(event.action)")
        }
      )
    )

    store.send(.startDelayed)
    await waitUntil {
      probe.events.contains("finish:instrumented-delayed")
    }

    #expect(store.state.log == ["delayed"])
    #expect(probe.events.contains("start:instrumented-delayed"))
    #expect(probe.events.contains("emit:received(\"delayed\")"))
    #expect(probe.events.contains("finish:instrumented-delayed"))
  }

  @Test("StoreInstrumentation.osLog preserves runtime behavior")
  func storeInstrumentationOSLogFactory() async {
    let logger = Logger(subsystem: "InnoFlowTests", category: "StoreInstrumentation")
    let store = Store(
      reducer: AsyncFeature(),
      initialState: .init(),
      instrumentation: .osLog(logger: logger)
    )

    store.send(.load)

    let timeoutClock = ContinuousClock()
    let deadline = timeoutClock.now.advanced(by: .seconds(2))
    while timeoutClock.now < deadline {
      if store.value == "Hello, InnoFlow v2" {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.value == "Hello, InnoFlow v2")
    #expect(store.isLoading == false)
  }

  @Test("StoreInstrumentation.sink captures unified lifecycle events in order")
  func storeInstrumentationSinkCapturesUnifiedEvents() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: AsyncFeature(),
      initialState: .init(),
      instrumentation: .sink { event in
        switch event {
        case .runStarted:
          probe.record("run-started")
        case .runFinished:
          probe.record("run-finished")
        case .actionEmitted(let actionEvent):
          probe.record("emit:\(actionEvent.action)")
        case .actionDropped:
          probe.record("dropped")
        case .effectsCancelled:
          probe.record("cancelled")
        }
      }
    )

    store.send(.load)
    await waitUntil {
      probe.events.last == "run-finished"
    }

    #expect(probe.events.first == "run-started")
    #expect(probe.events.contains("emit:_loaded(\"Hello, InnoFlow v2\")"))
    #expect(probe.events.last == "run-finished")
  }

  @Test("StoreInstrumentation.combined fans out events to every sink")
  func storeInstrumentationCombinedFansOut() async {
    let firstProbe = InstrumentationProbe()
    let secondProbe = InstrumentationProbe()
    let store = Store(
      reducer: AsyncFeature(),
      initialState: .init(),
      instrumentation: .combined(
        .sink { event in
          if case .actionEmitted(let actionEvent) = event {
            firstProbe.record("emit:\(actionEvent.action)")
          }
        },
        .sink { event in
          if case .actionEmitted(let actionEvent) = event {
            secondProbe.record("emit:\(actionEvent.action)")
          }
        }
      )
    )

    store.send(.load)
    try? await Task.sleep(for: .milliseconds(80))

    #expect(firstProbe.events == ["emit:_loaded(\"Hello, InnoFlow v2\")"])
    #expect(secondProbe.events == ["emit:_loaded(\"Hello, InnoFlow v2\")"])
  }

  @Test("Store instrumentation records cancellation and trailing throttle drop events")
  func storeInstrumentationCancellationAndDrop() async {
    let probe = InstrumentationProbe()
    let store = Store(
      reducer: InstrumentationFeature(),
      initialState: .init(),
      instrumentation: .init(
        didEmitAction: { event in
          probe.record("emit:\(event.action)")
        },
        didDropAction: { event in
          probe.record("drop:\(String(describing: event.action)):\(event.reason)")
        },
        didCancelEffects: { event in
          probe.record("cancel:\(event.id?.rawValue.description ?? "all")")
        }
      )
    )

    store.send(.startDelayed)
    try? await Task.sleep(for: .milliseconds(10))
    await store.cancelEffects(identifiedBy: "instrumented-delayed")
    try? await Task.sleep(for: .milliseconds(80))

    store.send(.trailingThrottle(1))
    for _ in 0..<10 {
      await Task.yield()
    }
    await store.cancelEffects(identifiedBy: "instrumented-throttle")
    try? await Task.sleep(for: .milliseconds(20))

    #expect(store.state.log.isEmpty)
    #expect(probe.events.contains("cancel:instrumented-delayed"))
    #expect(probe.events.contains("cancel:instrumented-throttle"))
    #expect(
      probe.events.contains(where: {
        $0.contains(
          "drop:Optional(InnoFlowTests.InstrumentationFeature.Action.received(\"delayed\")):cancellationBoundary"
        )
          || $0.contains(
            "drop:Optional(InnoFlowTests.InstrumentationFeature.Action.received(\"delayed\")):inactiveToken"
          )
      })
    )
    #expect(
      probe.events.contains(where: {
        $0.contains("drop:nil:throttledOrDebouncedCancellation")
      })
    )
  }

  @Test("Store instrumentation records storeReleased drops from late uncooperative emissions")
  func storeInstrumentationStoreReleasedDrop() async {
    let probe = InstrumentationProbe()
    let gate = LateSendGate()
    var store: Store<StoreReleaseDropFeature>? = Store(
      reducer: StoreReleaseDropFeature(gate: gate),
      initialState: .init(),
      instrumentation: .init(
        didDropAction: { event in
          probe.record("drop:\(String(describing: event.action)):\(event.reason)")
        },
        didCancelEffects: { event in
          probe.record("cancel:\(event.id?.rawValue.description ?? "all"):\(event.sequence)")
        }
      )
    )

    store?.send(.start)

    for _ in 0..<30 {
      if await gate.isWaiting {
        break
      }
      await Task.yield()
    }

    store = nil
    await gate.open()

    for _ in 0..<60 {
      if probe.events.contains(where: { $0.contains("storeReleased") }) {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(
      probe.events.contains(where: {
        $0.contains(
          "drop:Optional(InnoFlowTests.StoreReleaseDropFeature.Action._completed(\"late-value\")):storeReleased"
        )
      })
    )
    #expect(
      probe.events.contains(where: {
        $0.hasPrefix("cancel:all:")
      })
    )
  }

  @Test("Scoped observer registry tracks refresh passes without changing semantics")
  func scopedObserverRegistryRefreshCount() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.scope(state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)

    #expect(store.scopedObserverRefreshCount == 0)

    store.send(.setUnrelated(1))
    #expect(store.scopedObserverRefreshCount == 1)

    store.send(.child(.setStep(3)))
    #expect(store.scopedObserverRefreshCount == 2)
    #expect(store.child.step == 3)
  }

  @Test("EffectRuntime metrics snapshot tracks registration, cancellation, and finish counts")
  func effectRuntimeMetricsSnapshot() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RuntimeMetricsFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    await drainAsyncWork()

    let afterStart = await store.effectRuntimeMetrics
    #expect(afterStart.preparedRuns == 1)
    #expect(afterStart.attachedRuns == 1)
    #expect(afterStart.finishedRuns == 0)
    #expect(afterStart.cancellations == 0)

    await store.cancelEffects(identifiedBy: "runtime-metrics")
    await drainAsyncWork()

    let afterCancel = await store.effectRuntimeMetrics
    #expect(afterCancel.cancellations == 1)

    await clock.advance(by: .milliseconds(100))
    await drainAsyncWork()

    let afterCancelledFinish = await store.effectRuntimeMetrics
    #expect(afterCancelledFinish.preparedRuns == 1)
    #expect(afterCancelledFinish.attachedRuns == 1)
    #expect(afterCancelledFinish.finishedRuns == 1)
    #expect(store.completed == 0)

    store.send(.start)
    // The second run's Task must reach its `context.sleep(for:)` call and
    // register a sleeper on the ManualTestClock BEFORE we call advance(by:).
    // If advance runs first, it finds no sleeper to wake and the Task stays
    // suspended forever. `drainAsyncWork`'s fixed 128-yield budget is enough
    // on fast hardware but not on saturated CI — poll `sleeperCount` on a
    // wall-clock interval instead.
    for _ in 0..<500 {
      if await clock.sleeperCount >= 1 { break }
      try? await Task.sleep(for: .milliseconds(10))
    }
    await clock.advance(by: .milliseconds(100))
    for _ in 0..<250 {
      let metrics = await store.effectRuntimeMetrics
      if metrics.finishedRuns == 2,
        metrics.emissionDecisions >= 1,
        store.completed == 1
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    // After advance, the effect's sleep resumes on the cooperative executor.
    // Poll the observable completion marker so the check adapts to executor
    // jitter on saturated CI.
    await waitUntil(timeout: .seconds(5)) {
      store.completed == 1
    }

    let afterSuccessfulFinish = await store.effectRuntimeMetrics
    #expect(afterSuccessfulFinish.preparedRuns == 2)
    #expect(afterSuccessfulFinish.attachedRuns == 2)
    #expect(afterSuccessfulFinish.finishedRuns == 2)
    #expect(afterSuccessfulFinish.emissionDecisions >= 1)
    #expect(store.completed == 1)
  }

  @Test(
    "Projection observer stats track selective refresh for key-path, dependency, and closure selections"
  )
  func projectionObserverStatsTrackSelectiveRefresh() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.select(\.child)
    _ = store.select(dependingOn: \.child.title) { $0.uppercased() }
    _ = store.select { $0.child.title }

    let initial = store.projectionObserverStats
    #expect(initial.registeredObservers == 3)

    store.send(.setUnrelated(1))
    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers + 1)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)

    store.send(.child(.setStep(7)))
    let afterChildMutation = store.projectionObserverStats
    #expect(afterChildMutation.refreshPassCount == afterUnrelated.refreshPassCount + 1)
    #expect(afterChildMutation.evaluatedObservers == afterUnrelated.evaluatedObservers + 2)
    #expect(afterChildMutation.refreshedObservers == afterUnrelated.refreshedObservers + 1)

    store.send(.child(.setTitle("Ready")))
    let afterTitleMutation = store.projectionObserverStats
    #expect(afterTitleMutation.refreshPassCount == afterChildMutation.refreshPassCount + 1)
    #expect(afterTitleMutation.evaluatedObservers == afterChildMutation.evaluatedObservers + 3)
    #expect(afterTitleMutation.refreshedObservers == afterChildMutation.refreshedObservers + 3)
  }

  @Test(
    "Projection observer stats dedupe multi-field selections when multiple dependencies change in one action"
  )
  func projectionObserverStatsDedupeMultiFieldSelections() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.select(dependingOn: (\.child.step, \.child.title)) { step, title in
      "\(title)-\(step)"
    }

    let initial = store.projectionObserverStats
    #expect(initial.registeredObservers == 1)

    store.send(.child(.setSnapshot(step: 3, title: "Updated", note: "Ready")))

    let afterSnapshotMutation = store.projectionObserverStats
    #expect(afterSnapshotMutation.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterSnapshotMutation.evaluatedObservers == initial.evaluatedObservers + 1)
    #expect(afterSnapshotMutation.refreshedObservers == initial.refreshedObservers + 1)
  }

  @Test(
    "Projection observer stats dedupe six-field selections and fallback selectors still always refresh"
  )
  func projectionObserverStatsDedupeSixFieldSelections() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = store.select(
      dependingOn: (
        \.child.step,
        \.child.title,
        \.child.note,
        \.child.priority,
        \.child.isEnabled,
        \.child.version
      )
    ) { step, title, note, priority, isEnabled, version in
      "\(title)-\(step)-\(note)-\(priority)-\(isEnabled)-\(version)"
    }
    _ = store.select {
      "\($0.child.title)-\($0.child.step)-\($0.child.note)-\($0.child.priority)-\($0.child.isEnabled)-\($0.child.version)"
    }

    let initial = store.projectionObserverStats
    #expect(initial.registeredObservers == 2)

    store.send(.setUnrelated(1))

    let afterUnrelated = store.projectionObserverStats
    #expect(afterUnrelated.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers + 1)
    #expect(afterUnrelated.refreshedObservers == initial.refreshedObservers)

    store.send(
      .child(
        .setSelectionProbe(
          step: 3,
          title: "Updated",
          note: "Synced",
          priority: 4,
          isEnabled: false,
          version: 2
        )
      )
    )

    let afterProbeMutation = store.projectionObserverStats
    #expect(afterProbeMutation.refreshPassCount == afterUnrelated.refreshPassCount + 1)
    #expect(afterProbeMutation.evaluatedObservers == afterUnrelated.evaluatedObservers + 2)
    #expect(afterProbeMutation.refreshedObservers == afterUnrelated.refreshedObservers + 2)
  }

  @Test("Scoped projection stats track dependency-annotated and fallback selections")
  func scopedProjectionObserverStatsSelectiveRefresh() {
    let store = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    let scoped = store.scope(
      state: \.child, action: ScopedBindableChildFeature.Action.childCasePath)
    _ = scoped.select(\.step)
    _ = scoped.select(dependingOn: \.title) { $0.uppercased() }
    _ = scoped.select { $0.title }

    let initial = scoped.projectionObserverStats
    #expect(initial.registeredObservers == 3)

    store.send(.setUnrelated(1))
    let afterUnrelated = scoped.projectionObserverStats
    #expect(afterUnrelated.refreshPassCount == initial.refreshPassCount)
    #expect(afterUnrelated.evaluatedObservers == initial.evaluatedObservers)

    store.send(.child(.setStep(4)))
    let afterChildMutation = scoped.projectionObserverStats
    #expect(afterChildMutation.refreshPassCount == initial.refreshPassCount + 1)
    #expect(afterChildMutation.evaluatedObservers == initial.evaluatedObservers + 2)
    #expect(afterChildMutation.refreshedObservers == initial.refreshedObservers + 1)

    store.send(.child(.setTitle("Ready")))
    let afterTitleMutation = scoped.projectionObserverStats
    #expect(afterTitleMutation.refreshPassCount == afterChildMutation.refreshPassCount + 1)
    #expect(afterTitleMutation.evaluatedObservers == afterChildMutation.evaluatedObservers + 2)
    #expect(afterTitleMutation.refreshedObservers == afterChildMutation.refreshedObservers + 2)
  }

  @Test(
    "Projection observer registry compacts untouched dependency buckets on periodic maintenance")
  func projectionObserverRegistryPeriodicCompaction() {
    let registry = ProjectionObserverRegistry<ProjectionObserverSnapshot>(
      compactionDeadObserverThreshold: 99,
      periodicCompactionInterval: 2
    )

    do {
      let doomed = ProjectionObserverTestProbe()
      registry.register(
        doomed,
        registration: .dependency(
          .keyPath(\ProjectionObserverSnapshot.tracked),
          hasChanged: { previous, next in
            previous.tracked != next.tracked
          }
        )
      )
    }

    registry.refresh(
      from: .init(tracked: 0, other: 0),
      to: .init(tracked: 0, other: 1)
    )
    let afterFirstPass = registry.statsSnapshot
    #expect(afterFirstPass.registeredObservers == 1)
    #expect(afterFirstPass.compactionPassCount == 0)

    registry.refresh(
      from: .init(tracked: 0, other: 1),
      to: .init(tracked: 0, other: 2)
    )
    let afterSecondPass = registry.statsSnapshot
    #expect(afterSecondPass.registeredObservers == 0)
    #expect(afterSecondPass.compactionPassCount == 1)
    #expect(afterSecondPass.prunedObservers == 1)
  }

  @Test("Projection observer registry compacts untouched dependency buckets after stale threshold")
  func projectionObserverRegistryThresholdCompaction() {
    let registry = ProjectionObserverRegistry<ProjectionObserverSnapshot>(
      compactionDeadObserverThreshold: 1,
      periodicCompactionInterval: 100
    )

    do {
      let doomedAlways = ProjectionObserverTestProbe()
      registry.register(doomedAlways)

      let doomedDependency = ProjectionObserverTestProbe()
      registry.register(
        doomedDependency,
        registration: .dependency(
          .keyPath(\ProjectionObserverSnapshot.tracked),
          hasChanged: { previous, next in
            previous.tracked != next.tracked
          }
        )
      )
    }

    registry.refresh(
      from: .init(tracked: 0, other: 0),
      to: .init(tracked: 0, other: 1)
    )

    let stats = registry.statsSnapshot
    #expect(stats.registeredObservers == 0)
    #expect(stats.compactionPassCount == 1)
    #expect(stats.prunedObservers == 2)
  }

  @Test("Optional performance benchmarks print baselines when enabled")
  func optionalPerformanceBenchmarks() async {
    guard isPerformanceBenchmarkEnabled else { return }

    struct NoopRunBenchmarkFeature: Reducer {
      struct State: Equatable, Sendable, DefaultInitializable {}
      enum Action: Equatable, Sendable { case start }

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .start:
          return .run { _, _ in }
        }
      }
    }

    let runStore = Store(reducer: NoopRunBenchmarkFeature(), initialState: .init())
    let runClock = ContinuousClock()
    let runStart = runClock.now
    for _ in 0..<10_000 {
      runStore.send(.start)
    }
    for _ in 0..<20 {
      await drainAsyncWork()
    }
    let runDuration = runClock.now - runStart
    let runMetrics = await runStore.effectRuntimeMetrics
    print("InnoFlow benchmark: 10_000 no-op runs in \(runDuration), metrics=\(runMetrics)")

    let projectionStore = Store(reducer: ScopedBindableChildFeature(), initialState: .init())
    _ = projectionStore.select(\.child)
    let projectionClock = ContinuousClock()
    let projectionStart = projectionClock.now
    for index in 0..<1_000 {
      projectionStore.send(.setUnrelated(index))
    }
    let projectionDuration = projectionClock.now - projectionStart
    print(
      "InnoFlow benchmark: 1_000 projection refresh passes in \(projectionDuration), stats=\(projectionStore.projectionObserverStats)"
    )
  }

  @Test("Store processes immediate follow-up actions through a FIFO queue")
  func storeQueuedFollowUpActions() {
    let probe = ReducerDepthProbe()
    let store = Store(
      reducer: QueueDispatchFeature(probe: probe),
      initialState: .init()
    )

    store.send(.start)

    #expect(store.logs == ["start", "first", "second"])
    #expect(probe.actions == ["start", "first", "second"])
  }

  @Test("Store queue removes reducer reentrancy for immediate sends")
  func storeQueuePreventsReducerReentrancy() {
    let probe = ReducerDepthProbe()
    let store = Store(
      reducer: QueueDispatchFeature(probe: probe),
      initialState: .init()
    )

    store.send(.start)

    #expect(probe.maxDepth == 1)
  }

  @Test("Store queues async effect emissions back through the same dispatch loop")
  func storeAsyncEffectUsesQueueDispatch() async {
    let probe = ReducerDepthProbe()
    let store = Store(
      reducer: QueueDispatchFeature(probe: probe),
      initialState: .init()
    )

    store.send(.loadAsync)
    #expect(store.logs == ["loadAsync"])

    for _ in 0..<40 {
      if store.logs == ["loadAsync", "loadedAsync"] {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.logs == ["loadAsync", "loadedAsync"])
    #expect(probe.maxDepth == 1)
  }

  @Test("Store cancelEffects waits for cancellation bookkeeping")
  func storeCancelEffects() async {
    let store = Store(reducer: CancellableFeature(), initialState: .init())

    store.send(.start(1))
    await store.cancelEffects(identifiedBy: "load")

    try? await Task.sleep(for: .milliseconds(300))
    #expect(store.completed.isEmpty)
  }

  @Test("Store cancelAllEffects cancels pending effects")
  func storeCancelAllEffects() async {
    let store = Store(reducer: CancellableFeature(), initialState: .init())

    store.send(.start(1))
    await store.cancelAllEffects()

    try? await Task.sleep(for: .milliseconds(300))
    #expect(store.completed.isEmpty)
  }

  @Test("Store cancellation is idempotent and does not poison future effects")
  func storeCancellationIsReusable() async {
    let store = Store(reducer: CancellableFeature(), initialState: .init())

    store.send(.start(1))
    await store.cancelEffects(identifiedBy: "load")
    await store.cancelEffects(identifiedBy: "load")

    store.send(.start(2))

    for _ in 0..<40 {
      if store.completed == [2] {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.completed == [2])
    #expect(store.requested == 2)
  }

  @Test("Store .run drops post-cancellation emissions but keeps earlier values")
  func storeRunDropsPostCancellationEmissions() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start("first"))

    for _ in 0..<128 {
      if store.events.contains("first-1") {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.events.contains("first-1"))
    store.send(.cancel)
    await drainAsyncWork()
    await clock.advance(by: .milliseconds(140))
    await drainAsyncWork()

    #expect(store.events == ["first-1"])
  }

  @Test("Store .run keeps FIFO ordering for multiple emitted actions")
  func storeRunEmissionOrderingRemainsFIFO() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start("ordered"))

    for _ in 0..<128 {
      if store.events == ["ordered-1"] {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.events == ["ordered-1"])
    await clock.advance(by: .milliseconds(100))

    // Two more emissions (ordered-2, ordered-3) land as queued follow-up
    // actions after the sleep resumes. `drainAsyncWork`'s fixed yield budget
    // is sufficient on fast hardware but not on saturated CI executors —
    // poll the observable outcome with a wall-clock bounded wait instead.
    await waitUntil(timeout: .seconds(5)) {
      store.events.count >= 3
    }

    #expect(store.events == ["ordered-1", "ordered-2", "ordered-3"])
  }

  @Test("Store .run remains reusable after cancel and restart")
  func storeRunEmissionRecoversAfterRestart() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: RunEmissionBoundaryFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start("first"))
    for _ in 0..<128 {
      if store.events.contains("first-1") {
        break
      }
      await drainAsyncWork(iterations: 1)
    }
    #expect(store.events.contains("first-1"))

    store.send(.cancel)
    await drainAsyncWork()
    await clock.advance(by: .milliseconds(100))
    await drainAsyncWork()

    store.send(.start("second"))

    for _ in 0..<128 {
      if store.events == ["first-1", "second-1"] {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.events == ["first-1", "second-1"])
    await clock.advance(by: .milliseconds(100))

    // Same CI-executor-saturation risk as `storeRunEmissionOrderingRemainsFIFO`
    // above: after the advance, the two remaining emissions arrive as queued
    // follow-up actions. Poll observable state with a wall-clock bounded wait.
    await waitUntil(timeout: .seconds(5)) {
      store.events.count >= 4
    }

    #expect(store.events == ["first-1", "second-1", "second-2", "second-3"])
  }

  @Test("Lazy-mapped structured effects preserve ordering")
  func lazyMappedStructuredEffectsPreserveOrdering() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: LazyMappedEffectFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)

    for _ in 0..<128 {
      if store.values == ["first"] {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.values == ["first"])
    await drainAsyncWork(iterations: 128)
    await clock.advance(by: .milliseconds(80))

    for _ in 0..<128 {
      if store.values == ["first", "second"] {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.values == ["first", "second"])
  }

  @Test("Lazy-mapped structured effects honor cancellation")
  func lazyMappedStructuredEffectsHonorCancellation() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: LazyMappedEffectFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)

    for _ in 0..<128 {
      if store.values.contains("first") {
        break
      }
      await drainAsyncWork(iterations: 1)
    }

    #expect(store.values == ["first"])
    store.send(.cancel)
    await drainAsyncWork()
    await clock.advance(by: .milliseconds(120))
    await drainAsyncWork()

    #expect(store.values == ["first"])
  }

  @Test("Heavy stress: deep lazy map chains preserve ordering")
  func heavyStressLazyMapDeepChain() async {
    guard isHeavyStressEnabled else { return }

    let store = Store(
      reducer: DeepLazyMapStressFeature(chainDepth: 256),
      initialState: .init()
    )

    store.send(.start(0))

    for _ in 0..<50 {
      if store.values == [256, 257] {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(store.values == [256, 257])
  }

  @Test("Heavy stress: repeated lazy map materialization stays stable")
  func heavyStressLazyMapRepeatedMaterialization() async {
    guard isHeavyStressEnabled else { return }

    let store = Store(
      reducer: DeepLazyMapStressFeature(
        chainDepth: 128, cancellationID: "deep-lazy-map-repeat", includesAsyncTail: false),
      initialState: .init()
    )

    for seed in 0..<40 {
      store.send(.start(seed * 10))
    }

    #expect(store.values.count == 80)
    #expect(store.values.first == 128)
    #expect(store.values.last == 519)
  }

  @Test("Heavy stress: lazy map cancellation mix preserves semantics")
  func heavyStressLazyMapCancellationMix() async {
    guard isHeavyStressEnabled else { return }

    let store = Store(
      reducer: DeepLazyMapStressFeature(chainDepth: 64, cancellationID: "deep-lazy-map-cancel"),
      initialState: .init()
    )

    for seed in 0..<20 {
      store.send(.start(seed * 100))
      for _ in 0..<20 {
        if store.values.count == seed + 1 {
          break
        }
        try? await Task.sleep(for: .milliseconds(2))
      }
      store.send(.cancel)
      try? await Task.sleep(for: .milliseconds(5))
    }

    try? await Task.sleep(for: .milliseconds(80))

    #expect(store.values.count == 20)
    #expect(store.values.first == 64)
    #expect(store.values.last == 1964)
  }

  @Test("Deep lazy-map chains materialize without recursive lazy wrapper growth")
  func deepLazyMapChainStaysStable() async {
    let store = Store(
      reducer: DeepLazyMapStressFeature(chainDepth: 2048, includesAsyncTail: false),
      initialState: .init()
    )

    store.send(.start(0))

    for _ in 0..<40 {
      if store.values == [2048, 2049] {
        break
      }
      await Task.yield()
    }

    #expect(store.values == [2048, 2049])
  }

  @Test("Store drops emissions from cancelled uncooperative effects")
  func storeDropsCancelledEffectEmission() async {
    let store = Store(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )

    store.send(.start)
    await store.cancelEffects(identifiedBy: "uncooperative")

    try? await Task.sleep(for: .milliseconds(150))
    #expect(store.completed.isEmpty)
  }

  @Test("Store repeatedly drops late emissions after cancelEffects")
  func storeCancellationStress() async {
    let store = Store(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )
    let iterations = isHeavyStressEnabled ? 1_000 : 200

    for _ in 0..<iterations {
      store.send(.start)
      await store.cancelEffects(identifiedBy: "uncooperative")
    }

    try? await Task.sleep(for: .milliseconds(250))
    #expect(store.completed.isEmpty)
  }

  @Test("Store applies cancellation boundaries to merge and concatenate")
  func storeCancellationBoundaryOnComposedEffects() async {
    let store = Store(
      reducer: CompositeUncooperativeFeature(),
      initialState: .init()
    )

    for value in 0..<120 {
      store.send(.start(value))
      await store.cancelEffects(identifiedBy: "composite-uncooperative")
    }

    try? await Task.sleep(for: .milliseconds(300))
    #expect(store.completed.isEmpty)
  }

  @Test("Store combinator composition keeps debounce and throttle semantics")
  func storeCombinatorComposition() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: CombinatorCompositionFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start(1))
    // Wait for the first merge to fully dispatch: throttle emits its leading
    // value and debounce registers its sleeper. Under release optimization a
    // fixed yield count is fragile — poll for the observable outcome.
    for _ in 0..<200 {
      let count = await clock.sleeperCount
      if store.throttled == [1] && count >= 1 { break }
      await Task.yield()
    }

    store.send(.start(2))
    // The second merge's throttle must run and see the still-open window BEFORE
    // we advance the clock. If we advance first, the window is treated as
    // expired and the throttle emits the second value as a new leading emission.
    // Neither throttle_2's suppression nor debounce_2's replacement registration
    // produces a distinct observable state change (sleeperCount stays at 1
    // across the cancel+re-register), so we can only wait for the merge's
    // MainActor walker work to drain. A small wall-clock sleep on the system
    // ContinuousClock gives the cooperative executor a real chance to run
    // other tasks — more reliable than a fixed yield count on saturated CI.
    try? await Task.sleep(for: .milliseconds(100))

    await clock.advance(by: .milliseconds(50))
    await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(10)) {
      store.debounced == [2]
    }

    #expect(store.debounced == [2])
    #expect(store.throttled == [1])
  }

  @Test("CombineReducers runs parent reducers in declaration order and Scope lifts child effects")
  func composedReducersLiftChildEffects() async {
    let store = Store(
      reducer: ComposedReducerFeature(),
      initialState: .init()
    )

    store.send(.start)

    for _ in 0..<40 {
      if store.events == ["start", "parent saw child increment", "parent saw child report"] {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.child.value == 1)
    #expect(store.events == ["start", "parent saw child increment", "parent saw child report"])
  }

  @Test("Empty CombineReducers behaves like .none")
  func emptyCombineReducers() {
    let reducer = CombineReducers<BuilderCompositionFeature.State, BuilderCompositionFeature.Action>
    {
    }
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log.isEmpty)
    #expect(effect.isNone)
  }

  @Test("CombineReducers if-only builder paths keep semantics without exposing builder internals")
  func combineReducersOptionalBuilderPath() {
    let reducer = BuilderCompositionFeature.optionalBuilder(includeReducer: true)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log == ["optional"])
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_OptionalReducer<"))
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("CombineReducers if/else builder paths keep semantics without exposing builder internals")
  func combineReducersEitherBuilderPath() {
    let reducer = BuilderCompositionFeature.eitherBuilder(chooseFirst: false)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log == ["second"])
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_ConditionalReducer<"))
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("CombineReducers for-loops keep semantics without exposing builder internals")
  func combineReducersArrayBuilderPath() {
    let labels = ["first", "second", "third"]
    let reducer = BuilderCompositionFeature.arrayBuilder(labels: labels)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log == labels)
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_ArrayReducer<"))
    #expect(!String(reflecting: type(of: reducer)).contains("_ReducerBuilder"))
  }

  @Test("ReducerBuilder returns a stable public concrete type without builder wrappers")
  func combineReducersConcreteWrapperChain() {
    let reducer = BuilderCompositionFeature.straightLineBuilder()
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)
    let typeDescription = String(reflecting: type(of: reducer))

    #expect(state.log == ["first", "second"])
    #expect(effect.isNone)
    #expect(typeDescription.contains("_ReducerSequence<"))
    #expect(!typeDescription.contains("_ReducerBuilder"))
    #expect(!typeDescription.contains("[any Reducer"))
  }

  @Test("Builder preserves declaration order across mixed if/for/if-else/straight-line blocks")
  func combineReducersMixedBuilderBlock() {
    let reducer = CombineReducers<BuilderCompositionFeature.State, BuilderCompositionFeature.Action>
    {
      BuilderCompositionFeature.append("a")
      if true {
        BuilderCompositionFeature.append("b")
      }
      for label in ["c", "d"] {
        BuilderCompositionFeature.append(label)
      }
      if false {
        BuilderCompositionFeature.append("skipped-first")
      } else {
        BuilderCompositionFeature.append("else")
      }
      BuilderCompositionFeature.append("z")
    }
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    // Declaration order must be preserved across heterogeneous builder
    // constructs (expression, if-without-else, for, if/else, expression).
    #expect(state.log == ["a", "b", "c", "d", "else", "z"])
    #expect(effect.isNone)
  }

  @Test("Builder compiles and preserves order for N=32 straight-line block")
  func combineReducersN32StressPreservesOrder() {
    let reducer = CombineReducers<BuilderCompositionFeature.State, BuilderCompositionFeature.Action>
    {
      BuilderCompositionFeature.append("01")
      BuilderCompositionFeature.append("02")
      BuilderCompositionFeature.append("03")
      BuilderCompositionFeature.append("04")
      BuilderCompositionFeature.append("05")
      BuilderCompositionFeature.append("06")
      BuilderCompositionFeature.append("07")
      BuilderCompositionFeature.append("08")
      BuilderCompositionFeature.append("09")
      BuilderCompositionFeature.append("10")
      BuilderCompositionFeature.append("11")
      BuilderCompositionFeature.append("12")
      BuilderCompositionFeature.append("13")
      BuilderCompositionFeature.append("14")
      BuilderCompositionFeature.append("15")
      BuilderCompositionFeature.append("16")
      BuilderCompositionFeature.append("17")
      BuilderCompositionFeature.append("18")
      BuilderCompositionFeature.append("19")
      BuilderCompositionFeature.append("20")
      BuilderCompositionFeature.append("21")
      BuilderCompositionFeature.append("22")
      BuilderCompositionFeature.append("23")
      BuilderCompositionFeature.append("24")
      BuilderCompositionFeature.append("25")
      BuilderCompositionFeature.append("26")
      BuilderCompositionFeature.append("27")
      BuilderCompositionFeature.append("28")
      BuilderCompositionFeature.append("29")
      BuilderCompositionFeature.append("30")
      BuilderCompositionFeature.append("31")
      BuilderCompositionFeature.append("32")
    }
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)
    let expectedLog = (1...32).map { String(format: "%02d", $0) }

    #expect(state.log == expectedLog)
    #expect(effect.isNone)
  }

  @Test("Builder optional path with false condition yields .none effect and no state change")
  func combineReducersEmptyOptional() {
    let reducer = BuilderCompositionFeature.optionalBuilder(includeReducer: false)
    var state = BuilderCompositionFeature.State()

    let effect = reducer.reduce(into: &state, action: .run)

    #expect(state.log.isEmpty)
    #expect(effect.isNone)
    #expect(String(reflecting: type(of: reducer)).contains("_OptionalReducer<"))
  }

  @Test("Phase validation decorator allows same-phase actions and legal transitions")
  func phaseValidationDecorator() async {
    let store = Store(
      reducer: ValidatedPhaseReducer(),
      initialState: .init()
    )

    store.send(.noop)
    #expect(store.phase == .idle)

    store.send(.load)
    #expect(store.phase == .loading)

    store.send(.finish)
    #expect(store.phase == .loaded)
  }

  @Test("Store throttle trailing-only emits latest value at window end")
  func storeThrottleTrailingOnly() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(79))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    for _ in 0..<10 {
      if store.emitted == [2] {
        break
      }
      await Task.yield()
    }
    #expect(store.emitted == [2])
  }

  @Test("StoreClock deterministically drives debounce effects")
  func storeClockControlsDebounce() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: DebounceFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(59))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    for _ in 0..<10 {
      if store.emitted == [2] {
        break
      }
      await Task.yield()
    }

    #expect(store.emitted == [2])
  }

  @Test("ManualTestClock resumes same-deadline sleepers in insertion order")
  func manualTestClockResumesSameDeadlineSleepersInInsertionOrder() async {
    let clock = ManualTestClock()
    let probe = OrderedIntProbe()

    // Spawn two sleepers that hit the same deadline. The sleepers must be
    // registered with the clock before we advance — under release optimization
    // and parallel test load, a single `Task.yield()` between spawn and advance
    // is not reliable. Wait up to 200 yields for each Task to register before
    // proceeding.
    let firstSleeper = Task {
      try? await clock.sleep(for: .milliseconds(50))
      await probe.append(1)
    }
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    )

    let secondSleeper = Task {
      try? await clock.sleep(for: .milliseconds(50))
      await probe.append(2)
    }
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 2
      }
    )

    await clock.advance(by: .milliseconds(50))
    _ = await firstSleeper.result
    _ = await secondSleeper.result

    #expect(await probe.snapshot() == [1, 2])
  }

  @Test("ManualTestClock cancels pending sleepers without late resume")
  func manualTestClockCancelsPendingSleepersWithoutLateResume() async {
    let clock = ManualTestClock()
    let probe = OrderedIntProbe()

    let task = Task {
      do {
        try await clock.sleep(for: .milliseconds(50))
        await probe.append(1)
      } catch is CancellationError {
        await probe.append(-1)
      } catch {
        Issue.record("Expected CancellationError, got \(error)")
      }
    }

    await Task.yield()
    task.cancel()
    _ = await task.result

    await clock.advance(by: .milliseconds(50))
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await probe.snapshot() == [-1]
      }
    )

    #expect(await probe.snapshot() == [-1])
  }

  @Test("StoreClock deterministically drives trailing throttle effects")
  func storeClockControlsThrottleTrailing() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    for _ in 0..<10 {
      await Task.yield()
    }
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(79))
    #expect(store.emitted.isEmpty)

    await clock.advance(by: .milliseconds(1))
    for _ in 0..<10 {
      if store.emitted == [2] {
        break
      }
      await Task.yield()
    }

    #expect(store.emitted == [2])
  }

  @Test("StoreClock respects cancellation boundaries for debounced effects")
  func storeClockCancellationBoundary() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: DebounceFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.trigger(1))
    await store.cancelEffects(identifiedBy: "debounce-effect")
    await clock.advance(by: .milliseconds(60))
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(store.emitted.isEmpty)
  }

  @Test("EffectContext uses StoreClock for deterministic run timing")
  func effectContextUsesStoreClock() async {
    let clock = ManualTestClock()
    let store = Store(
      reducer: ContextClockFeature(),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    // `store.send` only guarantees the reducer has run; async effects dispatched
    // via `Task { ... }` still need scheduler turns to reach their first await.
    // Release optimization eliminates some scheduling boundaries, so a fixed
    // yield count is fragile — poll for the observable condition instead.
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
      store.state.log == ["started"]
    }

    #expect(store.state.log == ["started"])
    #expect(
      await waitUntilAsync(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
        await clock.sleeperCount == 1
      }
    )

    await clock.advance(by: .milliseconds(50))
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
      store.state.log == ["started", "finished"]
    }

    #expect(store.state.log == ["started", "finished"])
  }

  @Test("EffectContext.checkCancellation stays clear while a run remains active")
  func effectContextCheckCancellationPassesWhileActive() async {
    let clock = ManualTestClock()
    let probe = CancellationCheckProbe()
    let store = Store(
      reducer: CancellationCheckFeature(probe: probe),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    // Wait for the effect operation to reach its `context.sleep(...)`
    // suspension point before advancing the clock. `store.send` only guarantees
    // reducer completion; the `.run` body runs through several actor hops before
    // registering the sleeper, and release optimization eliminates some of the
    // scheduling boundaries that a fixed yield count relied on — poll instead.
    for _ in 0..<200 {
      if await probe.started == 1 { break }
      await Task.yield()
    }

    await clock.advance(by: .milliseconds(10))

    for _ in 0..<200 {
      if await probe.passed == 1 { break }
      await Task.yield()
    }

    #expect(await probe.started == 1)
    #expect(await probe.ready == 1)
    #expect(await probe.passed == 1)
    #expect(await probe.cancelled == 0)

    await store.cancelEffects(identifiedBy: "context-check")
  }

  @Test("EffectContext.checkCancellation throws after cancelEffects")
  func effectContextCheckCancellationThrowsAfterCancelEffects() async {
    let clock = ManualTestClock()
    let probe = CancellationCheckProbe()
    let store = Store(
      reducer: CancellationCheckFeature(probe: probe),
      initialState: .init(),
      clock: .manual(clock)
    )

    store.send(.start)
    for _ in 0..<200 {
      if await probe.started == 1 { break }
      await Task.yield()
    }

    await clock.advance(by: .milliseconds(10))
    for _ in 0..<200 {
      if await probe.passed == 1 { break }
      await Task.yield()
    }

    await store.cancelEffects(identifiedBy: "context-check")
    for _ in 0..<200 {
      if await probe.cancelled == 1 { break }
      await Task.yield()
    }

    #expect(await probe.cancelled == 1)
  }

  @Test("TestStore preserves first emission from merge-wrapped sequential effects")
  @MainActor
  func testStorePreservesMergeWrappedSequentialEffects() async {
    let store = TestStore(reducer: SequentialMergeFeature())

    await store.send(.start)
    await store.receive(._first) {
      $0.received = ["first"]
    }
    await store.receive(._second) {
      $0.received = ["first", "second"]
    }
    await store.assertNoMoreActions()
  }

  @Test("Store throttle leading+trailing skips trailing when no extra event")
  func storeThrottleLeadingTrailingSingleEvent() async {
    let store = Store(
      reducer: ThrottleLeadingTrailingFeature(),
      initialState: .init()
    )

    store.send(.trigger(1))
    try? await Task.sleep(for: .milliseconds(160))
    #expect(store.emitted == [1])
  }

  @Test("Store cancelEffects drops pending throttle trailing emission")
  func storeThrottleTrailingCancelledByID() async {
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init()
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    await store.cancelEffects(identifiedBy: "throttle-trailing")

    try? await Task.sleep(for: .milliseconds(120))
    #expect(store.emitted.isEmpty)
  }

  @Test("Store cancelAllEffects drops pending throttle trailing emission")
  func storeThrottleTrailingCancelledByAll() async {
    let store = Store(
      reducer: ThrottleTrailingFeature(),
      initialState: .init()
    )

    store.send(.trigger(1))
    store.send(.trigger(2))
    await store.cancelAllEffects()

    try? await Task.sleep(for: .milliseconds(120))
    #expect(store.emitted.isEmpty)
  }

  @Test("Store deinit prevents long-running effect completion")
  func storeDeinitPreventsLongRunningCompletion() async {
    let probe = DeinitCancellationProbe()
    var store: Store<DeinitCancellationFeature>? = Store(
      reducer: DeinitCancellationFeature(probe: probe),
      initialState: .init()
    )

    store?.send(.start)

    for _ in 0..<100 {
      if await probe.started == 1 {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    store = nil

    for _ in 0..<150 {
      if await probe.cancelled == 1 {
        break
      }
      if await probe.completed > 0 {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(await probe.started == 1)
    #expect(await probe.completed == 0)
    #expect(await probe.cancelled == 1)
  }

  @Test("EffectContext.checkCancellation throws after store release")
  func effectContextCheckCancellationThrowsAfterStoreRelease() async {
    let clock = ManualTestClock()
    let probe = CancellationCheckProbe()
    var store: Store<CancellationCheckFeature>? = Store(
      reducer: CancellationCheckFeature(probe: probe),
      initialState: .init(),
      clock: .manual(clock)
    )

    store?.send(.start)
    for _ in 0..<10 {
      await Task.yield()
    }

    await clock.advance(by: .milliseconds(10))

    for _ in 0..<30 {
      if await probe.passed == 1 {
        break
      }
      await Task.yield()
    }

    store = nil

    for _ in 0..<30 {
      if await probe.cancelled == 1 {
        break
      }
      await Task.yield()
    }

    #expect(await probe.cancelled == 1)
  }
}

// MARK: - TestStore Tests

@Suite("TestStore Tests", .serialized)
@MainActor
struct TestStoreTests {

  @Test("TestStore validates send + receive with deterministic flow")
  func testStoreReceive() async {
    let store = TestStore(
      reducer: AsyncFeature(),
      initialState: .init(),
      // CI can heavily saturate the cooperative executor while multiple suites
      // start together. Keep this basic smoke test tolerant of startup jitter;
      // the stronger 40-iteration test below still validates deterministic
      // first-delivery behavior under the tighter budget.
      effectTimeout: .seconds(60)
    )

    await store.send(.load) {
      $0.isLoading = true
    }

    await store.receive(._loaded("Hello, InnoFlow v2")) {
      $0.value = "Hello, InnoFlow v2"
      $0.isLoading = false
    }

    await store.assertNoMoreActions()
  }

  @Test("TestStore run effects deliver their first emission deterministically")
  func testStoreRunEffectsDeliverFirstEmissionDeterministically() async {
    for _ in 0..<40 {
      let store = TestStore(
        reducer: AsyncFeature(),
        initialState: .init(),
        effectTimeout: .seconds(3)
      )

      await store.send(.load) {
        $0.isLoading = true
      }

      await store.receive(._loaded("Hello, InnoFlow v2")) {
        $0.value = "Hello, InnoFlow v2"
        $0.isLoading = false
      }

      await store.assertNoMoreActions()
    }
  }

  @Test("TestStore async cancellation API prevents pending effect emission")
  func testStoreCancelEffects() async {
    let store = TestStore(reducer: CancellableFeature(), initialState: .init())

    await store.send(.start(1)) {
      $0.requested = 1
    }

    await store.cancelEffects(identifiedBy: "load")
    await store.assertNoMoreActions()
  }

  @Test("TestStore drops emissions from cancelled uncooperative effects")
  func testStoreDropsCancelledEffectEmission() async {
    let store = TestStore(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )

    await store.send(.start)
    await store.cancelEffects(identifiedBy: "uncooperative")
    await store.assertNoMoreActions()
  }

  @Test("TestStore repeated cancellation stress keeps queue clean")
  func testStoreCancellationStress() async {
    let store = TestStore(
      reducer: UncooperativeCancellableFeature(),
      initialState: .init()
    )
    let iterations = isHeavyStressEnabled ? 1_000 : 120

    for _ in 0..<iterations {
      await store.send(.start)
      await store.cancelEffects(identifiedBy: "uncooperative")
    }

    await store.assertNoMoreActions()
  }

  @Test("TestStore diff renderer reports nested paths")
  func stateDiffRenderer() {
    struct NestedState: Equatable, Sendable {
      var phase = "loading"
      var items = [Item(title: "Draft"), Item(title: "Draft")]

      struct Item: Equatable, Sendable {
        var title: String
      }
    }

    let diff = renderStateDiff(
      expected: NestedState(phase: "loaded", items: [.init(title: "Draft"), .init(title: "Done")]),
      actual: NestedState(phase: "loading", items: [.init(title: "Draft"), .init(title: "Draft")])
    )

    #expect(diff?.contains("phase: expected \"loaded\", actual \"loading\"") == true)
    #expect(diff?.contains("items[1].title: expected \"Done\", actual \"Draft\"") == true)
  }

  @Test("TestStore diff renderer uses the default 12-line cap")
  func stateDiffRendererUsesDefaultCap() {
    let diff = renderStateDiff(
      expected: Array(0..<20),
      actual: Array(100..<120)
    )

    #expect(diff?.split(separator: "\n").count == 12)
  }

  @Test("TestStore diff renderer returns nil when lineLimit is non-positive")
  func stateDiffRendererNilForNonPositiveLineLimit() {
    let diff = renderStateDiff(
      expected: [1, 2, 3],
      actual: [4, 5, 6],
      lineLimit: 0
    )

    #expect(diff == nil)
  }

  @Test("TestStore diff renderer uses stable summary output for sets")
  func stateDiffRendererUsesStableSetSummary() {
    let diff = renderStateDiff(
      expected: Set(["beta", "alpha"]),
      actual: Set(["gamma", "alpha"])
    )

    #expect(diff == #"state: expected Set(["alpha", "beta"]), actual Set(["alpha", "gamma"])"#)
  }

  @Test("TestStore diff renderer treats reordered dictionaries as equal")
  func stateDiffRendererIgnoresDictionaryInsertionOrder() {
    let expected = ["alpha": 1, "beta": 2]
    let actual = Dictionary(uniqueKeysWithValues: [("beta", 2), ("alpha", 1)])

    let diff = renderStateDiff(expected: expected, actual: actual)

    #expect(diff == nil)
  }

  @Test("TestStore diff line limit resolves env and explicit overrides")
  func testStoreDiffLineLimitResolution() {
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "18"]
      ) == 18
    )
    #expect(
      resolveDiffLineLimit(
        explicit: 5,
        environment: [testStoreDiffLineLimitEnvironmentKey: "18"]
      ) == 5
    )
    #expect(
      resolveDiffLineLimit(
        explicit: 0,
        environment: [testStoreDiffLineLimitEnvironmentKey: "18"]
      ) == 0
    )
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "0"]
      ) == 0
    )
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "-3"]
      ) == defaultStateDiffLineLimit
    )
    #expect(
      resolveDiffLineLimit(
        explicit: nil,
        environment: [testStoreDiffLineLimitEnvironmentKey: "abc"]
      ) == defaultStateDiffLineLimit
    )
  }

  @Test("ScopedTestStore inherits the resolved parent diff line limit")
  func scopedTestStoreInheritsParentDiffLimit() {
    let store = TestStore(
      reducer: ScopedTestHarnessFeature(),
      initialState: .init(),
      diffLineLimit: 3
    )
    let child = store.scope(state: \.child, action: ScopedTestHarnessFeature.Action.childCasePath)

    #expect(store.resolvedDiffLineLimit == 3)
    #expect(child.resolvedDiffLineLimit == 3)
  }

  @Test("TestStore phase helper ignores same-phase actions and validates legal transitions")
  func testStorePhaseHelperSamePhase() async {
    let store = TestStore(reducer: ValidatedPhaseReducer(), initialState: .init())

    await store.send(.noop, tracking: \.phase, through: ValidatedPhaseReducer.graph)
    await store.send(.load, tracking: \.phase, through: ValidatedPhaseReducer.graph) {
      $0.phase = .loading
    }
    await store.send(.finish, tracking: \.phase, through: ValidatedPhaseReducer.graph) {
      $0.phase = .loaded
    }
  }

  @Test("PhaseMap applies basic and payload-aware transitions through the testing helper")
  func phaseMapBasicAndPayloadAwareTransitions() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(reducer: PhaseMapHarness(), initialState: .init())

    await store.send(.load, through: map) {
      $0.phase = .loading
      $0.errorMessage = nil
    }

    await store.send(.loaded([1, 2, 3]), through: map) {
      $0.phase = .loaded
      $0.values = [1, 2, 3]
      $0.errorMessage = nil
    }
  }

  @Test("PhaseMap ignores unmatched actions and source phases")
  func phaseMapIgnoresUnmatchedTransitions() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(reducer: PhaseMapHarness(), initialState: .init())

    await store.send(.noop, through: map)
    #expect(store.state.phase == .idle)

    await store.send(.loaded([42]), through: map) {
      $0.values = [42]
      $0.errorMessage = nil
    }
    #expect(store.state.phase == .idle)
  }

  @Test("PhaseMap guard uses post-reduce state for conditional targets")
  func phaseMapGuardUsesPostReduceState() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(
      reducer: PhaseMapHarness(),
      initialState: .init(phase: .failed, values: [], errorMessage: "boom")
    )

    await store.send(.replaceAndDismiss([7]), through: map) {
      $0.phase = .loaded
      $0.values = [7]
      $0.errorMessage = nil
    }
  }

  @Test("PhaseMap treats nil or same-phase guard results as no-op transitions")
  func phaseMapGuardNoOps() async {
    let map: PhaseMap<PhaseMapHarness.State, PhaseMapHarness.Action, PhaseMapHarness.State.Phase> =
      PhaseMapHarness.phaseMap
    let store = TestStore(
      reducer: PhaseMapHarness(),
      initialState: .init(phase: .failed, values: [1], errorMessage: "boom")
    )

    await store.send(.maybeRecover(false), through: map)
    #expect(store.state.phase == .failed)

    await store.send(.replaceAndDismiss([]), through: map) {
      $0.phase = .idle
      $0.values = []
      $0.errorMessage = nil
    }
  }

  @Test("PhaseMap uses declared ordering when multiple transitions match")
  func phaseMapFirstMatchWins() async {
    let map:
      PhaseMap<
        PhaseMapOrderingHarness.State, PhaseMapOrderingHarness.Action,
        PhaseMapOrderingHarness.State.Phase
      > = PhaseMapOrderingHarness.phaseMap
    let store = TestStore(reducer: PhaseMapOrderingHarness(), initialState: .init())

    await store.send(.advance, through: map) {
      $0.phase = .first
    }
  }

  @Test("PhaseMap preserves ordering across separate rule blocks for the same source phase")
  func phaseMapPreservesOrderingAcrossSeparateRuleBlocks() async {
    struct Harness: Reducer {
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
          }
          From(.idle) {
            On(where: { $0 == .advance }, targets: [.second]) { _, _ in .second }
          }
        }
      }

      func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        Reduce<State, Action> { _, _ in .none }
          .phaseMap(Self.phaseMap)
          .reduce(into: &state, action: action)
      }
    }

    let store = TestStore(reducer: Harness(), initialState: .init())

    await store.send(.advance, through: Harness.phaseMap) {
      $0.phase = .first
    }
    await store.assertNoMoreActions()
  }

  @Test("PhaseMap derivedGraph can be validated with existing graph helpers")
  func phaseMapDerivedGraphValidation() {
    let graph: PhaseTransitionGraph<PhaseMapHarness.State.Phase> = PhaseMapHarness.phaseGraph
    assertValidGraph(
      graph,
      allPhases: [.idle, .loading, .loaded, .failed],
      root: .idle
    )
    #expect(graph.successors(from: .failed) == [.idle, .loaded])
  }

  @Test("PhaseMap opt-in validation reports clean coverage when expected triggers are declared")
  func phaseMapValidationReportCoveredTriggers() {
    let report = PhaseMapHarness.phaseMap.validationReport(
      expectedTriggersByPhase: [
        .idle: [
          .action(.load)
        ],
        .loading: [
          .casePath(PhaseMapHarness.loadedCasePath, label: "loaded", sample: [1, 2, 3]),
          .casePath(PhaseMapHarness.failedCasePath, label: "failed", sample: "boom"),
        ],
        .failed: [
          .casePath(
            PhaseMapHarness.replaceAndDismissCasePath, label: "replaceAndDismiss", sample: [7]),
          .casePath(PhaseMapHarness.maybeRecoverCasePath, label: "maybeRecover", sample: true),
        ],
      ]
    )

    #expect(report.isEmpty)
    #expect(report.missingTriggers.isEmpty)
  }

  @Test(
    "PhaseMap opt-in validation reports missing triggers while runtime semantics stay partial-by-default"
  )
  func phaseMapValidationReportMissingTriggers() async {
    let report = PhaseMapHarness.phaseMap.validationReport(
      expectedTriggersByPhase: [
        .idle: [
          .action(.noop, label: "noop")
        ],
        .failed: [
          .action(.load, label: "retry load")
        ],
      ]
    )

    #expect(report.isEmpty == false)
    #expect(
      Set(report.missingTriggers)
        == Set([
          .init(sourcePhase: .idle, trigger: "noop"),
          .init(sourcePhase: .failed, trigger: "retry load"),
        ])
    )

    let store = TestStore(reducer: PhaseMapHarness(), initialState: .init())
    await store.send(.noop, through: PhaseMapHarness.phaseMap)
    #expect(store.state.phase == .idle)
  }

  @Test("PhaseMap validation report combines repeated source-phase blocks via the source index")
  func phaseMapValidationReportUsesIndexedRulesForRepeatedSourcePhases() {
    enum Phase: Hashable, Sendable {
      case idle
      case loading
      case loaded
      case failed
    }

    struct State: Equatable, Sendable {
      var phase: Phase
    }

    enum Action: Equatable, Sendable {
      case load
      case loaded([Int])
      case failed(String)
    }

    let loadedCasePath = CasePath<Action, [Int]>(
      embed: Action.loaded,
      extract: { action in
        guard case .loaded(let payload) = action else { return nil }
        return payload
      }
    )

    let failedCasePath = CasePath<Action, String>(
      embed: Action.failed,
      extract: { action in
        guard case .failed(let payload) = action else { return nil }
        return payload
      }
    )

    let map = PhaseMap<State, Action, Phase>(\.phase) {
      From(.idle) {
        On(.load, to: .loading)
      }
      From(.loading) {
        On(loadedCasePath, to: .loaded)
      }
      From(.loading) {
        On(failedCasePath, to: .failed)
      }
    }

    let report = map.validationReport(
      expectedTriggersByPhase: [
        .loading: [
          .casePath(loadedCasePath, label: "loaded", sample: [1, 2, 3]),
          .casePath(failedCasePath, label: "failed", sample: "boom"),
        ]
      ]
    )

    #expect(report.isEmpty)
    #expect(report.missingTriggers.isEmpty)
  }

  @Test("PhaseMap supports predicate-based fixed-target, nil-guard, and same-phase guard paths")
  func phaseMapPredicatePaths() async {
    let map:
      PhaseMap<
        PhaseMapPredicateHarness.State,
        PhaseMapPredicateHarness.Action,
        PhaseMapPredicateHarness.State.Phase
      > = PhaseMapPredicateHarness.phaseMap
    let store = TestStore(reducer: PhaseMapPredicateHarness(), initialState: .init())

    await store.send(.start, through: map) {
      $0.phase = .loading
    }

    await store.send(.configure(false), through: map) {
      $0.phase = .loading
      $0.shouldAdvance = false
    }

    await store.send(.refresh, through: map) {
      $0.phase = .loading
    }

    await store.send(.configure(true), through: map) {
      $0.phase = .loaded
      $0.shouldAdvance = true
    }
  }

  @Test("CasePath round-trips embedded values")
  func casePathRoundTrip() {
    let childAction = ScopedTestHarnessFeature.ChildAction.finished
    let rootAction = ScopedTestHarnessFeature.Action.childCasePath.embed(childAction)

    #expect(rootAction == .child(.finished))
    #expect(ScopedTestHarnessFeature.Action.childCasePath.extract(rootAction) == childAction)
    #expect(ScopedTestHarnessFeature.Action.childCasePath.extract(.child(.start)) == .start)
  }

  @Test("assertCasePathExtracts returns the matched case payload")
  func assertCasePathExtractsSuccess() throws {
    let rootAction = ScopedTestHarnessFeature.Action.child(.finished)
    let extracted = try #require(
      assertCasePathExtracts(
        rootAction,
        via: ScopedTestHarnessFeature.Action.childCasePath,
        caseName: "child"
      )
    )

    #expect(extracted == .finished)
  }

  @Test("assertCasePathExtracts formats mismatch context for diagnostics")
  func assertCasePathExtractsFailureFormatting() {
    enum ProbeRoot: Equatable, Sendable {
      case child(Int)
      case other(String)
    }

    let message = casePathExtractionFailureMessage(
      root: ProbeRoot.other("unexpected"),
      caseName: "child"
    )

    #expect(message.contains("expected case path did not match") == true)
    #expect(message.contains("Expected case: child") == true)
    #expect(message.contains("ProbeRoot") == true)
    #expect(message.contains("other") == true)
  }

  @Test("CollectionActionPath round-trips embedded values")
  func collectionActionPathRoundTrip() {
    let childAction = ScopedCollectionFeature.TodoAction.setDone(true)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let rootAction = ScopedCollectionFeature.Action.todoActionPath.embed(id, childAction)

    #expect(rootAction == .todo(id: id, action: .setDone(true)))
    #expect(ScopedCollectionFeature.Action.todoActionPath.extract(rootAction)?.0 == id)
    #expect(ScopedCollectionFeature.Action.todoActionPath.extract(rootAction)?.1 == childAction)
    #expect(ScopedCollectionFeature.Action.todoActionPath.extract(.moveLastToFront) == nil)
  }

  @Test("ScopedTestStore forwards child actions through the parent TestStore")
  func scopedTestStoreSendAndReceive() async {
    let store = TestStore(
      reducer: ScopedTestHarnessFeature(),
      initialState: .init()
    )
    let child = store.scope(state: \.child, action: ScopedTestHarnessFeature.Action.childCasePath)

    await child.send(.start) {
      $0.log = ["start"]
    }
    await child.receive(.finished) {
      $0.log = ["start", "finished"]
    }
    await child.assertNoMoreActions()
  }

  @Test("ScopedTestStore collection helper targets a single element by id")
  func scopedTestStoreCollectionProjection() async {
    let store = TestStore(
      reducer: ScopedCollectionFeature(),
      initialState: .init()
    )
    let targetID = store.state.todos[1].id
    let todo = store.scope(
      collection: \.todos,
      id: targetID,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    #expect(todo.title == "Two")
    #expect(todo.isDone == false)

    await todo.send(.setDone(true)) {
      $0.isDone = true
    }

    #expect(store.state.todos[0].isDone == false)
    #expect(store.state.todos[1].isDone == true)
    #expect(store.state.todos[2].isDone == false)
  }

  @Test("ScopedTestStore assert helper verifies current child state")
  func scopedTestStoreAssertHelper() async {
    let store = TestStore(
      reducer: ScopedCollectionFeature(),
      initialState: .init()
    )
    let targetID = store.state.todos[1].id
    let todo = store.scope(
      collection: \.todos,
      id: targetID,
      action: ScopedCollectionFeature.Action.todoActionPath
    )

    await todo.send(.setDone(true))
    todo.assert {
      $0.isDone = true
    }
  }

  @Test("ThrottleStateMap.clearState cancels trailing task and clears pending state")
  @MainActor
  func throttleStateMapClearState() {
    let map = ThrottleStateMap<CounterFeature.Action>()
    let id: EffectID = "throttle-clear-state"
    let task = Task<Void, Never> {
      try? await Task.sleep(for: .seconds(5))
    }

    map.setWindowEnd(ContinuousClock().now, for: id)
    map.storePending(.send(.increment), context: nil, for: id)
    _ = map.nextGeneration(for: id)
    map.setTrailingTask(task, for: id)
    map.clearState(for: id)

    #expect(map.windowEnd(for: id) == nil)
    #expect(map.pending(for: id) == nil)
    #expect(map.generation(for: id) == nil)
    #expect(task.isCancelled)
  }

  @Test("ThrottleStateMap.clearAll cancels all trailing tasks and clears stored state")
  @MainActor
  func throttleStateMapClearAll() {
    let map = ThrottleStateMap<CounterFeature.Action>()
    let firstID: EffectID = "throttle-clear-all-1"
    let secondID: EffectID = "throttle-clear-all-2"
    let firstTask = Task<Void, Never> {
      try? await Task.sleep(for: .seconds(5))
    }
    let secondTask = Task<Void, Never> {
      try? await Task.sleep(for: .seconds(5))
    }

    map.setWindowEnd(ContinuousClock().now, for: firstID)
    map.setWindowEnd(ContinuousClock().now, for: secondID)
    map.storePending(.send(.increment), context: nil, for: firstID)
    map.storePending(.send(.decrement), context: nil, for: secondID)
    _ = map.nextGeneration(for: firstID)
    _ = map.nextGeneration(for: secondID)
    map.setTrailingTask(firstTask, for: firstID)
    map.setTrailingTask(secondTask, for: secondID)
    map.clearAll()

    #expect(map.windowEnd(for: firstID) == nil)
    #expect(map.windowEnd(for: secondID) == nil)
    #expect(map.pending(for: firstID) == nil)
    #expect(map.pending(for: secondID) == nil)
    #expect(map.generation(for: firstID) == nil)
    #expect(map.generation(for: secondID) == nil)
    #expect(firstTask.isCancelled)
    #expect(secondTask.isCancelled)
  }

  // MARK: - C-1: merge/concatenate .none normalization

  @Test("EffectTask.merge filters out all .none children and returns .none")
  func mergeAllNoneReturnsNone() {
    let effect: EffectTask<CounterFeature.Action> = .merge([.none, .none, .none])
    #expect(effect.isNone)
  }

  @Test("EffectTask.merge unwraps single live child after filtering .none")
  func mergeSingleLiveUnwraps() {
    let effect: EffectTask<CounterFeature.Action> = .merge([.none, .send(.increment), .none])
    if case .send(let action) = effect.operation {
      #expect(action == .increment)
    } else {
      Issue.record("Expected .send(.increment), got \(effect.operation)")
    }
  }

  @Test("EffectTask.concatenate filters out all .none children and returns .none")
  func concatenateAllNoneReturnsNone() {
    let effect: EffectTask<CounterFeature.Action> = .concatenate([.none, .none])
    #expect(effect.isNone)
  }

  @Test("EffectTask.concatenate unwraps single live child after filtering .none")
  func concatenateSingleLiveUnwraps() {
    let effect: EffectTask<CounterFeature.Action> = .concatenate([.none, .send(.increment), .none])
    if case .send(let action) = effect.operation {
      #expect(action == .increment)
    } else {
      Issue.record("Expected .send(.increment), got \(effect.operation)")
    }
  }

  @Test("EffectTask.map lazily wraps structured effects")
  func mappedStructuredEffectsUseLazyWrapper() {
    let childEffect: EffectTask<LazyMappedEffectFeature.ChildAction> = .concatenate(
      .send(.immediate("first")),
      .run { _ in }
    )
    .cancellable("lazy-wrapper-shape", cancelInFlight: true)

    let mapped = childEffect.map { childAction in
      switch childAction {
      case .immediate(let value), .delayed(let value):
        return LazyMappedEffectFeature.Action.value(value)
      }
    }

    if case .lazyMap = mapped.operation {
      // expected shape
    } else {
      Issue.record("Expected lazy-mapped operation, got \(mapped.operation)")
    }
  }

  @Test("EffectTask.map(identity) preserves the materialized effect tree")
  func effectMapIdentityLaw() {
    let source: EffectTask<Int> = .concatenate(
      .merge(
        .send(1).cancellable("map-identity-cancellable"),
        .send(2).debounce("map-identity-debounce", for: .seconds(1))
      ),
      .send(3).throttle("map-identity-throttle", for: .seconds(2), leading: true, trailing: true)
    )

    let mapped = source.map { $0 }

    #expect(effectOperationSignature(source) == effectOperationSignature(mapped))
  }

  @Test("EffectTask.map composition preserves the materialized effect tree")
  func effectMapCompositionLaw() {
    let source: EffectTask<Int> = .merge(
      .send(1).cancellable("map-composition-cancellable", cancelInFlight: true),
      .send(2).throttle(
        "map-composition-throttle", for: .seconds(1), leading: false, trailing: true)
    )

    let lhs =
      source
      .map { "value-\($0)" }
      .map { $0.uppercased() }
    let rhs = source.map { value in
      "VALUE-\(value)"
    }

    #expect(effectOperationSignature(lhs) == effectOperationSignature(rhs))
  }

  @Test("EffectTask.concatenate uses .none as a left identity")
  func effectConcatenateLeftIdentityLaw() {
    let effect: EffectTask<Int> = .merge(
      .send(1),
      .send(2).throttle("concat-left-throttle", for: .seconds(1), leading: false, trailing: true)
    )

    let lhs = EffectTask<Int>.concatenate(.none, effect)

    #expect(effectOperationSignature(lhs) == effectOperationSignature(effect))
  }

  @Test("EffectTask.concatenate uses .none as a right identity")
  func effectConcatenateRightIdentityLaw() {
    let effect: EffectTask<Int> = .merge(
      .send(1).cancellable("concat-right-cancellable"),
      .send(2)
    )

    let rhs = EffectTask<Int>.concatenate(effect, .none)

    #expect(effectOperationSignature(rhs) == effectOperationSignature(effect))
  }

  @Test("EffectTask.concatenate preserves associativity on the materialized effect tree")
  func effectConcatenateAssociativityLaw() {
    let first: EffectTask<Int> = .send(1)
    let second: EffectTask<Int> = .send(2).debounce("concat-assoc-debounce", for: .seconds(1))
    let third: EffectTask<Int> = .send(3).cancellable("concat-assoc-cancellable")

    let lhs = EffectTask<Int>.concatenate(.concatenate(first, second), third)
    let rhs = EffectTask<Int>.concatenate(first, .concatenate(second, third))

    #expect(normalizedConcatenateSignature(lhs) == normalizedConcatenateSignature(rhs))
  }

  @Test("CombineReducers empty builder acts as the identity reducer")
  func combineReducersEmptyIdentity() {
    let reducer = CombineReducers<CounterFeature.State, CounterFeature.Action> {}
    var state = CounterFeature.State(count: 41)
    let effect = reducer.reduce(into: &state, action: .increment)

    #expect(state.count == 41)
    #expect(effect.isNone)
  }

  @Test("CombineReducers respects identity reducers on both sides")
  func combineReducersIdentityLaw() {
    let identity = Reduce<CounterFeature.State, CounterFeature.Action> { _, _ in .none }
    let increment = Reduce<CounterFeature.State, CounterFeature.Action> { state, action in
      guard action == .increment else { return .none }
      state.count += 1
      return .none
    }

    let left = CombineReducers<CounterFeature.State, CounterFeature.Action> {
      identity
      increment
    }
    let right = CombineReducers<CounterFeature.State, CounterFeature.Action> {
      increment
      identity
    }

    var leftState = CounterFeature.State(count: 0)
    var rightState = CounterFeature.State(count: 0)
    let leftEffect = left.reduce(into: &leftState, action: .increment)
    let rightEffect = right.reduce(into: &rightState, action: .increment)

    #expect(leftState == CounterFeature.State(count: 1))
    #expect(rightState == CounterFeature.State(count: 1))
    #expect(effectOperationSignature(leftEffect) == effectOperationSignature(rightEffect))
  }

  @Test("CombineReducers grouping preserves straight-line state semantics")
  func combineReducersAssociativeStateSemantics() {
    struct TraceState: Equatable, Sendable {
      var trace: [String] = []
    }

    enum TraceAction: Sendable {
      case run
    }

    let first = Reduce<TraceState, TraceAction> { state, action in
      guard case .run = action else { return .none }
      state.trace.append("first")
      return .none
    }
    let second = Reduce<TraceState, TraceAction> { state, action in
      guard case .run = action else { return .none }
      state.trace.append("second")
      return .none
    }
    let third = Reduce<TraceState, TraceAction> { state, action in
      guard case .run = action else { return .none }
      state.trace.append("third")
      return .none
    }

    let left = CombineReducers<TraceState, TraceAction> {
      first
      CombineReducers {
        second
        third
      }
    }
    let right = CombineReducers<TraceState, TraceAction> {
      CombineReducers {
        first
        second
      }
      third
    }

    var leftState = TraceState()
    var rightState = TraceState()
    _ = left.reduce(into: &leftState, action: .run)
    _ = right.reduce(into: &rightState, action: .run)

    #expect(leftState == rightState)
    #expect(leftState.trace == ["first", "second", "third"])
  }

  // MARK: - T-2: BindableProperty CustomReflectable

  @Test("BindableProperty diff shows field name directly without .value intermediate")
  func bindablePropertyDiffIsTransparent() {
    struct BindableState: Equatable {
      var step: BindableProperty<Int>
    }

    let diff = renderStateDiff(
      expected: BindableState(step: BindableProperty(5)),
      actual: BindableState(step: BindableProperty(10))
    )
    #expect(diff != nil)
    #expect(diff?.contains("step") == true)
    #expect(diff?.contains("step.value") != true)
  }
}

@Suite("Stale Scope Crash Contract Tests", .serialized)
struct StaleScopeCrashContractTests {
  @Test("Stale ScopedStore parent-release contract crashes in a subprocess")
  func staleScopedStoreParentReleaseContract() throws {
    let result = try runStaleScopedStoreHarness(scenario: .parentReleased)

    #expect(result.status != 0)
    #expect(
      result.normalizedOutput.contains("regenerate the scoped store from parent state") == true)
    #expect(result.normalizedOutput.contains("ParentReleasedFeature") == true)
  }

  @Test("Stale collection-scoped store contract crashes in a subprocess")
  func staleScopedCollectionContract() throws {
    let result = try runStaleScopedStoreHarness(scenario: .collectionEntryRemoved)

    #expect(result.status != 0)
    #expect(result.normalizedOutput.contains("source collection entry") == true)
    #expect(result.normalizedOutput.contains("CollectionRemovedFeature") == true)
  }

  @Test("Stale SelectedStore parent-release contract crashes in a subprocess")
  func staleSelectedStoreParentReleaseContract() throws {
    let result = try runStaleScopedStoreHarness(scenario: .selectedParentReleased)

    #expect(result.status != 0)
    #expect(result.normalizedOutput.contains("SelectedStore") == true)
    #expect(result.normalizedOutput.contains("parent store was released") == true)
  }
}

@Suite("Stale Scope Release Contract Tests", .serialized)
struct StaleScopeReleaseContractTests {
  @Test("Stale ScopedStore returns cached state after parent release in release-like execution")
  func staleScopedStoreReleaseNoCrash() throws {
    let result = try runStaleScopedStoreReleaseHarness(scenario: .parentReleased)

    #expect(result.status == 0)
  }

  @Test("Stale collection-scoped ScopedStore tolerates removed entry in release-like execution")
  func staleCollectionScopeReleaseNoCrash() throws {
    let result = try runStaleScopedStoreReleaseHarness(scenario: .collectionEntryRemoved)

    #expect(result.status == 0)
  }

  @Test("Stale SelectedStore returns cached value after parent release in release-like execution")
  func staleSelectedStoreReleaseNoCrash() throws {
    let result = try runStaleScopedStoreReleaseHarness(scenario: .selectedParentReleased)

    #expect(result.status == 0)
  }
}

@Suite("PhaseMap Crash Contract Tests", .serialized)
struct PhaseMapCrashContractTests {
  @Test("PhaseMap direct phase mutations crash in a subprocess with contextual diagnostics")
  func phaseMapDirectMutationCrashContract() throws {
    let result = try runPhaseMapCrashHarness(scenario: .directMutationCrash)

    #expect(result.status != 0)
    #expect(
      result.normalizedOutput.contains(
        "Base reducer must not mutate phase directly when PhaseMap is active.") == true)
    #expect(result.normalizedOutput.contains("action:") == true)
    #expect(result.normalizedOutput.contains("previousPhase:") == true)
    #expect(result.normalizedOutput.contains("postReducePhase:") == true)
    #expect(result.normalizedOutput.contains("phaseKeyPath:") == true)
  }

  @Test("PhaseMap undeclared dynamic targets crash in a subprocess with contextual diagnostics")
  func phaseMapUndeclaredTargetCrashContract() throws {
    let result = try runPhaseMapCrashHarness(scenario: .undeclaredTargetCrash)

    #expect(result.status != 0)
    #expect(
      result.normalizedOutput.contains("PhaseMap resolved a target outside the declared targets.")
        == true)
    #expect(result.normalizedOutput.contains("action:") == true)
    #expect(result.normalizedOutput.contains("sourcePhase:") == true)
    #expect(result.normalizedOutput.contains("target:") == true)
    #expect(result.normalizedOutput.contains("declaredTargets:") == true)
  }

  @Test(
    "PhaseMap restores the previous phase before applying declared transitions in release-like execution"
  )
  func phaseMapRestoresDirectMutationInReleaseLikeExecution() throws {
    let result = try runPhaseMapReleaseHarness(scenario: .directMutationRestore)

    #expect(result.status == 0)
  }

  @Test(
    "PhaseMap ignores undeclared dynamic targets while preserving non-phase reducer work in release-like execution"
  )
  func phaseMapRejectsUndeclaredDynamicTargetsInReleaseLikeExecution() throws {
    let result = try runPhaseMapReleaseHarness(scenario: .undeclaredTargetNoOp)

    #expect(result.status == 0)
  }
}

@Suite("Conditional Reducer Release Contract Tests", .serialized)
struct ConditionalReducerReleaseContractTests {
  @Test("IfLet drops child actions as a release-safe no-op when optional state is nil")
  func ifLetReleaseNoOpWhenStateAbsent() throws {
    let result = try runConditionalReducerReleaseHarness(scenario: .ifLetAbsentState)

    #expect(result.status == 0)
  }

  @Test("IfCaseLet drops child actions as a release-safe no-op when the case does not match")
  func ifCaseLetReleaseNoOpWhenCaseMismatches() throws {
    let result = try runConditionalReducerReleaseHarness(scenario: .ifCaseLetMismatchedState)

    #expect(result.status == 0)
  }
}

// MARK: - Compile Contract Helpers

private func effectOperationSignature<Action: Sendable>(_ effect: EffectTask<Action>) -> String {
  switch effect.operation {
  case .none:
    return "none"

  case .send(let action):
    return "send(\(String(describing: action)))"

  case .run(let priority, _):
    return "run(priority:\(String(describing: priority)))"

  case .merge(let children):
    return "merge(\(children.map(effectOperationSignature).joined(separator: ",")))"

  case .concatenate(let children):
    return "concatenate(\(children.map(effectOperationSignature).joined(separator: ",")))"

  case .cancel(let id):
    return "cancel(\(id.rawValue.description))"

  case .cancellable(let nested, let id, let cancelInFlight):
    return
      "cancellable(id:\(id.rawValue.description),cancelInFlight:\(cancelInFlight),nested:\(effectOperationSignature(nested)))"

  case .debounce(let nested, let id, let interval):
    return
      "debounce(id:\(id.rawValue.description),interval:\(interval),nested:\(effectOperationSignature(nested)))"

  case .throttle(let nested, let id, let interval, let leading, let trailing):
    return
      "throttle(id:\(id.rawValue.description),interval:\(interval),leading:\(leading),trailing:\(trailing),nested:\(effectOperationSignature(nested)))"

  case .animation(let nested, let animation):
    return "animation(\(String(describing: animation)),nested:\(effectOperationSignature(nested)))"

  case .lazyMap(let lazy):
    return effectOperationSignature(lazy.materialize())
  }
}

private func normalizedConcatenateSignature<Action: Sendable>(_ effect: EffectTask<Action>)
  -> String
{
  switch effect.operation {
  case .concatenate(let children):
    return
      children
      .flatMap(flattenConcatenateChildren)
      .map(effectOperationSignature)
      .joined(separator: " -> ")

  default:
    return effectOperationSignature(effect)
  }
}

private func flattenConcatenateChildren<Action: Sendable>(_ effect: EffectTask<Action>)
  -> [EffectTask<Action>]
{
  switch effect.operation {
  case .concatenate(let children):
    return children.flatMap(flattenConcatenateChildren)

  default:
    return [effect]
  }
}

private enum TimingScenarioStep: Sendable {
  case trigger(Int)
  case advance(Int)
}

private func makeTimingScenario(
  seed: UInt64,
  maxSteps: Int = 100
) -> [TimingScenarioStep] {
  var rng = SeededGenerator(seed: seed)
  let count = rng.nextInt(upperBound: maxSteps - 20) + 20
  var steps: [TimingScenarioStep] = []

  for index in 0..<count {
    if index == 0 || rng.nextInt(upperBound: 100) < 60 {
      steps.append(.trigger(rng.nextInt(upperBound: 10_000)))
    } else {
      steps.append(.advance(rng.nextInt(upperBound: 120) + 1))
    }
  }

  steps.append(.advance(200))
  return steps
}

private func expectedDebounceOutputs(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int
) -> [Int] {
  var time = 0
  var pending: (value: Int, due: Int)?
  var emitted: [Int] = []

  for step in steps {
    switch step {
    case .trigger(let value):
      pending = (value, time + intervalMilliseconds)

    case .advance(let delta):
      time += delta
      if let scheduled = pending, scheduled.due <= time {
        emitted.append(scheduled.value)
        pending = nil
      }
    }
  }

  return emitted
}

private func expectedThrottleOutputs(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int,
  leading: Bool,
  trailing: Bool
) -> [Int] {
  precondition(leading || trailing)

  var time = 0
  var windowEnd: Int?
  var pending: Int?
  var emitted: [Int] = []

  for step in steps {
    switch step {
    case .trigger(let value):
      if let activeWindowEnd = windowEnd, time < activeWindowEnd {
        if trailing {
          pending = value
        }
        continue
      }

      windowEnd = time + intervalMilliseconds
      pending = nil

      if leading {
        emitted.append(value)
      } else if trailing {
        pending = value
      }

    case .advance(let delta):
      time += delta
      if let activeWindowEnd = windowEnd, activeWindowEnd <= time {
        if trailing, let pending {
          emitted.append(pending)
        }
        windowEnd = nil
        pending = nil
      }
    }
  }

  return emitted
}

@MainActor
private func runTimingScenario<R: Reducer>(
  reducer: R,
  steps: [TimingScenarioStep],
  trigger: @escaping (Int) -> R.Action,
  emitted: KeyPath<R.State, [Int]>,
  expectedCount: Int
) async -> [Int]
where
  R.State: Equatable & Sendable & DefaultInitializable,
  R.Action: Sendable
{
  let clock = ManualTestClock()
  let store = Store(
    reducer: reducer,
    initialState: .init(),
    clock: .manual(clock)
  )

  for step in steps {
    switch step {
    case .trigger(let value):
      store.send(trigger(value))
      await settleTimingScenarioWork()

    case .advance(let milliseconds):
      await settleTimingScenarioWork()
      await clock.advance(by: .milliseconds(milliseconds))
      await settleTimingScenarioWork()
    }
  }

  await waitForEmissionCount(
    store,
    emitted: emitted,
    minimumCount: expectedCount
  )

  return store.state[keyPath: emitted]
}

private func settleTimingScenarioWork() async {
  // `Store.send` schedules non-`.send` effects onto a separate Task. For the
  // randomized debounce/throttle property tests, some in-window updates only
  // mutate internal pending state and do not immediately change user-visible
  // state or sleeper counts. A pure `Task.yield()` loop can therefore advance
  // the manual clock before the walker Task has actually applied the pending
  // replacement under release optimization. Add a tiny wall-clock handoff so
  // the queued Task gets a real executor turn before the scenario continues.
  await drainAsyncWork(iterations: 64)
  try? await Task.sleep(for: .milliseconds(1))
  await drainAsyncWork(iterations: 64)
}

@MainActor
private func waitForEmissionCount<R: Reducer>(
  _ store: Store<R>,
  emitted: KeyPath<R.State, [Int]>,
  minimumCount: Int,
  maxIterations: Int = 1_024
) async {
  guard minimumCount > 0 else { return }

  for _ in 0..<maxIterations {
    if store.state[keyPath: emitted].count >= minimumCount {
      return
    }
    await Task.yield()
  }
}

private func drainAsyncWork(iterations: Int = 128) async {
  for _ in 0..<iterations {
    await Task.yield()
  }
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(20),
  condition: @escaping @MainActor () -> Bool
) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if condition() {
      return
    }
    try? await Task.sleep(for: pollInterval)
  }
}

private func waitUntilAsync(
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(20),
  settleIterations: Int = 16,
  condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if await condition() {
      return true
    }
    await drainAsyncWork(iterations: settleIterations)
    try? await Task.sleep(for: pollInterval)
  }

  return await condition()
}

@MainActor
private func waitForProjectionObserverStats<R: Reducer>(
  _ store: Store<R>,
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(10),
  condition: @escaping @MainActor (ProjectionObserverRegistryStats) -> Bool
) async {
  await waitUntil(timeout: timeout, pollInterval: pollInterval) {
    condition(store.projectionObserverStats)
  }
}

@MainActor
private func waitForProjectionRefreshPass<R: Reducer>(
  _ store: Store<R>,
  after previousStats: ProjectionObserverRegistryStats,
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(10)
) async {
  await waitForProjectionObserverStats(
    store,
    timeout: timeout,
    pollInterval: pollInterval
  ) { stats in
    stats.refreshPassCount > previousStats.refreshPassCount
  }
}

private var isHeavyStressEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_HEAVY_STRESS"] == "1"
}

private var isPerformanceBenchmarkEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_PERF_BENCHMARKS"] == "1"
}

private struct SeededGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
  }

  mutating func next() -> UInt64 {
    state = 2_862_933_555_777_941_757 &* state &+ 3_037_000_493
    return state
  }

  mutating func nextInt(upperBound: Int) -> Int {
    precondition(upperBound > 0)
    return Int(next() % UInt64(upperBound))
  }
}

private struct TypecheckResult {
  let status: Int32
  let output: String
}

extension TypecheckResult {
  fileprivate var normalizedOutput: String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class ThreadSafeDataBuffer: Sendable {
  private let data = OSAllocatedUnfairLock<Data>(initialState: .init())

  func append(_ chunk: Data) {
    data.withLock { $0.append(chunk) }
  }

  func snapshot() -> Data {
    data.withLock { $0 }
  }
}

private enum CompileContractError: Error, CustomStringConvertible {
  case moduleNotFound(attemptedPaths: [String])

  var description: String {
    switch self {
    case .moduleNotFound(let attemptedPaths):
      let formattedPaths =
        attemptedPaths
        .map { "- \($0)" }
        .joined(separator: "\n")
      return """
        Failed to locate InnoFlow.swiftmodule.
        Attempted search locations:
        \(formattedPaths)
        """
    }
  }
}

private func findBuiltModuleDirectory(
  named moduleName: String,
  in packageRoot: URL,
  configuration: String? = nil
) throws -> URL {
  let fileManager = FileManager.default
  let buildDirectory = packageRoot.appendingPathComponent(".build", isDirectory: true)
  var attemptedPaths: [String] = [
    packageRoot.path,
    buildDirectory.path,
    buildDirectory.appendingPathComponent("debug", isDirectory: true).path,
    buildDirectory.appendingPathComponent("release", isDirectory: true).path,
    buildDirectory.appendingPathComponent("arm64-apple-macosx/debug", isDirectory: true).path,
    buildDirectory.appendingPathComponent("x86_64-apple-macosx/debug", isDirectory: true).path,
    buildDirectory.appendingPathComponent("arm64-apple-macosx/release", isDirectory: true).path,
    buildDirectory.appendingPathComponent("x86_64-apple-macosx/release", isDirectory: true).path,
  ]
  if let buildChildren = try? fileManager.contentsOfDirectory(
    at: buildDirectory,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
  ) {
    for child in buildChildren {
      attemptedPaths.append(child.path)
      attemptedPaths.append(child.appendingPathComponent("debug", isDirectory: true).path)
      attemptedPaths.append(child.appendingPathComponent("release", isDirectory: true).path)
    }
  }
  attemptedPaths = Array(Set(attemptedPaths)).sorted()

  guard
    let enumerator = fileManager.enumerator(
      at: buildDirectory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
  else {
    throw CompileContractError.moduleNotFound(attemptedPaths: attemptedPaths)
  }

  for case let fileURL as URL in enumerator
  where fileURL.lastPathComponent == "\(moduleName).swiftmodule" {
    if let configuration,
      !fileURL.path.contains("/\(configuration)/")
    {
      continue
    }
    return fileURL.deletingLastPathComponent()
  }

  throw CompileContractError.moduleNotFound(attemptedPaths: attemptedPaths)
}

private func findBuiltInnoFlowModuleDirectory(
  in packageRoot: URL,
  configuration: String? = nil
) throws -> URL {
  try findBuiltModuleDirectory(
    named: "InnoFlow",
    in: packageRoot,
    configuration: configuration
  )
}

private func typecheckSource(
  _ source: String,
  moduleDirectory: URL
) throws -> TypecheckResult {
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("CompileContract.swift")
  try source.write(to: sourceFile, atomically: true, encoding: .utf8)

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "swiftc",
    "-typecheck",
    sourceFile.path,
    "-I",
    moduleDirectory.path,
  ]

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  let stdoutBuffer = ThreadSafeDataBuffer()
  let stderrBuffer = ThreadSafeDataBuffer()

  stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stdoutBuffer.append(data)
  }

  stderrPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stderrBuffer.append(data)
  }

  try process.run()
  process.waitUntilExit()

  stdoutPipe.fileHandleForReading.readabilityHandler = nil
  stderrPipe.fileHandleForReading.readabilityHandler = nil

  var stderrData = stderrBuffer.snapshot()

  var stdoutData = stdoutBuffer.snapshot()
  let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
  let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  if !stdoutTail.isEmpty {
    stdoutData.append(stdoutTail)
  }
  if !stderrTail.isEmpty {
    stderrData.append(stderrTail)
  }

  let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
  let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

  return TypecheckResult(
    status: process.terminationStatus,
    output: stdoutText + "\n" + stderrText
  )
}

private struct ProcessResult {
  let status: Int32
  let output: String
}

extension ProcessResult {
  fileprivate var normalizedOutput: String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private enum StaleScopedStoreScenario: String {
  case parentReleased = "parent-released"
  case collectionEntryRemoved = "collection-entry-removed"
  case selectedParentReleased = "selected-parent-released"
}

private enum StaleScopeHarnessError: Error, CustomStringConvertible {
  case objectFilesNotFound(buildDirectory: String)
  case compileFailed(output: String)

  var description: String {
    switch self {
    case .objectFilesNotFound(let buildDirectory):
      return "Failed to locate compiled InnoFlow object files in \(buildDirectory)"
    case .compileFailed(let output):
      return "Failed to compile stale scope harness.\n\(output)"
    }
  }
}

private func currentInnoFlowPackageRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

private func findBuiltObjectFiles(
  for targetName: String,
  in packageRoot: URL,
  configuration: String? = nil
) throws -> [URL] {
  let buildDirectory = packageRoot.appendingPathComponent(".build", isDirectory: true)
  guard
    let enumerator = FileManager.default.enumerator(
      at: buildDirectory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
  else {
    throw StaleScopeHarnessError.objectFilesNotFound(buildDirectory: buildDirectory.path)
  }

  let objectFiles =
    (enumerator.compactMap { $0 as? URL })
    .filter {
      $0.pathExtension == "o"
        && $0.deletingLastPathComponent().lastPathComponent == "\(targetName).build"
        && (configuration == nil || $0.path.contains("/\(configuration!)/"))
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

  guard !objectFiles.isEmpty else {
    throw StaleScopeHarnessError.objectFilesNotFound(buildDirectory: buildDirectory.path)
  }

  return objectFiles
}

private func findBuiltInnoFlowObjectFiles(
  in packageRoot: URL,
  configuration: String? = nil
) throws -> [URL] {
  try findBuiltObjectFiles(
    for: "InnoFlow",
    in: packageRoot,
    configuration: configuration
  )
}

private func runProcess(
  executableURL: URL,
  arguments: [String],
  environment: [String: String] = [:],
  currentDirectoryURL: URL? = nil
) throws -> ProcessResult {
  let process = Process()
  process.executableURL = executableURL
  process.arguments = arguments
  process.currentDirectoryURL = currentDirectoryURL

  if !environment.isEmpty {
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
      mergedEnvironment[key] = value
    }
    process.environment = mergedEnvironment
  }

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  let stdoutBuffer = ThreadSafeDataBuffer()
  let stderrBuffer = ThreadSafeDataBuffer()

  stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stdoutBuffer.append(data)
  }

  stderrPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stderrBuffer.append(data)
  }

  try process.run()
  process.waitUntilExit()

  stdoutPipe.fileHandleForReading.readabilityHandler = nil
  stderrPipe.fileHandleForReading.readabilityHandler = nil

  var stdoutData = stdoutBuffer.snapshot()
  var stderrData = stderrBuffer.snapshot()

  let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
  if !stdoutTail.isEmpty {
    stdoutData.append(stdoutTail)
  }
  if !stderrTail.isEmpty {
    stderrData.append(stderrTail)
  }

  return ProcessResult(
    status: process.terminationStatus,
    output: (String(data: stdoutData, encoding: .utf8) ?? "")
      + "\n"
      + (String(data: stderrData, encoding: .utf8) ?? "")
  )
}

private func runStaleScopedStoreHarness(
  scenario: StaleScopedStoreScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("StaleScopeProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("StaleScopeProbe")
  try staleScopedStoreHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  // Inline-compile InnoFlow sources with the probe at `-Onone` so debug-only
  // `assertionFailure` traps are live and so the build is independent of the
  // enclosing `swift test` configuration (previously we linked `.build/*/*.o`,
  // which produced duplicate-symbol link errors under `swift test -c release`
  // whenever both debug and release `.build/` directories existed).
  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-Onone",
      "-parse-as-library",
      "-package-name", "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o", executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw StaleScopeHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_STALE_SCOPE_SCENARIO": scenario.rawValue]
  )
}

private enum ConditionalReducerReleaseScenario: String {
  case ifLetAbsentState = "iflet-absent-state"
  case ifCaseLetMismatchedState = "ifcase-mismatched-state"
}

private enum StaleScopedStoreReleaseScenario: String {
  case parentReleased = "parent-released"
  case collectionEntryRemoved = "collection-entry-removed"
  case selectedParentReleased = "selected-parent-released"
}

private func runStaleScopedStoreReleaseHarness(
  scenario: StaleScopedStoreReleaseScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("StaleScopeReleaseProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("StaleScopeReleaseProbe")
  try staleScopedStoreReleaseHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-O",
      "-parse-as-library",
      "-package-name",
      "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o",
      executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw StaleScopeHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_STALE_SCOPE_RELEASE_SCENARIO": scenario.rawValue]
  )
}

private enum PhaseMapCrashScenario: String {
  case directMutationCrash = "direct-mutation-crash"
  case undeclaredTargetCrash = "undeclared-target-crash"
}

private enum PhaseMapReleaseScenario: String {
  case directMutationRestore = "direct-mutation-restore"
  case undeclaredTargetNoOp = "undeclared-target-noop"
}

private enum ConditionalReducerHarnessError: Error, CustomStringConvertible {
  case compileFailed(output: String)

  var description: String {
    switch self {
    case .compileFailed(let output):
      return "Failed to compile conditional reducer release harness.\n\(output)"
    }
  }
}

private enum PhaseMapHarnessError: Error, CustomStringConvertible {
  case compileFailed(output: String)

  var description: String {
    switch self {
    case .compileFailed(let output):
      return "Failed to compile PhaseMap harness.\n\(output)"
    }
  }
}

private func runConditionalReducerReleaseHarness(
  scenario: ConditionalReducerReleaseScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("ConditionalReducerProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("ConditionalReducerProbe")
  try conditionalReducerReleaseHarnessSource.write(
    to: sourceFile, atomically: true, encoding: .utf8)

  let coreSources = [
    "BindableField.swift",
    "BindableProperty.swift",
    "CasePath.swift",
    "CollectionActionPath.swift",
    "EffectRuntime.swift",
    "EffectDriver.swift",
    "EffectTask.swift",
    "EffectTask+SwiftUI.swift",
    "EffectWalker.swift",
    "Reducer.swift",
    "ReducerComposition.swift",
    "ScopedStore.swift",
    "SelectedStore.swift",
    "Store.swift",
    "Store+EffectDriver.swift",
    "Store+SwiftUIPreviews.swift",
    "StoreClock.swift",
    "StoreEffectBridge.swift",
    "StoreInstrumentation.swift",
    "StoreLifetimeToken.swift",
    "ProjectionObserverRegistry.swift",
    "StoreActionQueue.swift",
    "StoreCaches.swift",
  ]
  .map { packageRoot.appendingPathComponent("Sources/InnoFlow/\($0)").path }

  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-O",
      "-parse-as-library",
      "-package-name",
      "InnoFlow",
      sourceFile.path,
    ] + coreSources + [
      "-o",
      executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw ConditionalReducerHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_CONDITIONAL_REDUCER_SCENARIO": scenario.rawValue]
  )
}

private func innoFlowCoreSourcePaths(in packageRoot: URL) throws -> [String] {
  try FileManager.default
    .contentsOfDirectory(
      at: packageRoot.appendingPathComponent("Sources/InnoFlow", isDirectory: true),
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "InnoFlow.swift" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map(\.path)
}

private func runPhaseMapCrashHarness(
  scenario: PhaseMapCrashScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("PhaseMapCrashProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("PhaseMapCrashProbe")
  try phaseMapCrashHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  // Inline-compile InnoFlow sources with the probe at `-Onone` so the
  // PhaseMap `assertionFailure` traps we are asserting on are live, and so
  // the build is independent of the enclosing `swift test` configuration.
  // Previously we linked `.build/*/*.o`, which surfaced duplicate-symbol
  // link errors under `swift test -c release` whenever both debug and
  // release `.build/` directories existed.
  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-Onone",
      "-parse-as-library",
      "-package-name", "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o", executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw PhaseMapHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_PHASEMAP_CRASH_SCENARIO": scenario.rawValue]
  )
}

private func runPhaseMapReleaseHarness(
  scenario: PhaseMapReleaseScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("PhaseMapReleaseProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("PhaseMapReleaseProbe")
  try phaseMapReleaseHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-O",
      "-parse-as-library",
      "-package-name",
      "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o",
      executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw PhaseMapHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_PHASEMAP_RELEASE_SCENARIO": scenario.rawValue]
  )
}

private let conditionalReducerReleaseHarnessSource = #"""
  import Foundation

  struct ReleaseIfLetFeature: Reducer {
    struct ChildState: Equatable, Sendable {
      var count = 0
    }

    struct State: Equatable, Sendable {
      var child: ChildState?
      var untouched = 7
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case increment
    }

    struct ChildReducer: Reducer {
      func reduce(into state: inout ChildState, action: ChildAction) -> EffectTask<ChildAction> {
        switch action {
        case .increment:
          state.count += 1
          return .none
        }
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      CombineReducers<State, Action> {
        Reduce { _, _ in .none }
        IfLet(
          state: \.child,
          action: Action.childCasePath,
          reducer: ChildReducer()
        )
      }
      .reduce(into: &state, action: action)
    }
  }

  struct ReleaseIfCaseLetFeature: Reducer {
    struct ChildState: Equatable, Sendable {
      var count = 0
    }

    enum State: Equatable, Sendable {
      case idle
      case child(ChildState)
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case increment
    }

    static let childStateCasePath = CasePath<State, ChildState>(
      embed: State.child,
      extract: { state in
        guard case .child(let childState) = state else { return nil }
        return childState
      }
    )

    struct ChildReducer: Reducer {
      func reduce(into state: inout ChildState, action: ChildAction) -> EffectTask<ChildAction> {
        switch action {
        case .increment:
          state.count += 1
          return .none
        }
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      CombineReducers<State, Action> {
        Reduce { _, _ in .none }
        IfCaseLet(
          state: Self.childStateCasePath,
          action: Action.childCasePath,
          reducer: ChildReducer()
        )
      }
      .reduce(into: &state, action: action)
    }
  }

  @main
  struct ConditionalReducerProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_CONDITIONAL_REDUCER_SCENARIO"] {
      case "iflet-absent-state":
        let store = Store(
          reducer: ReleaseIfLetFeature(),
          initialState: .init(child: nil, untouched: 7)
        )
        store.send(.child(.increment))
        guard store.state == .init(child: nil, untouched: 7) else {
          fputs("IfLet mutated state unexpectedly\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      case "ifcase-mismatched-state":
        let store = Store(
          reducer: ReleaseIfCaseLetFeature(),
          initialState: .idle
        )
        store.send(.child(.increment))
        guard store.state == .idle else {
          fputs("IfCaseLet mutated state unexpectedly\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      default:
        fputs("Unknown conditional reducer scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#

private let staleScopedStoreHarnessSource = #"""
  import Foundation

  struct ParentReleasedFeature: Reducer {
    struct Child: Equatable, Sendable {
      var value = 1
    }

    struct State: Equatable, Sendable {
      var child = Child()
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case noop
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      .none
    }
  }

  struct CollectionRemovedFeature: Reducer {
    struct Todo: Identifiable, Equatable, Sendable {
      let id: UUID
      var title: String
    }

    struct State: Equatable, Sendable {
      var todos: [Todo] = [
        Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "One")
      ]
      var routedActions: [String] = []
    }

    enum Action: Equatable, Sendable {
      case todo(id: UUID, action: TodoAction)
      case remove(id: UUID)

      static let todoActionPath = CollectionActionPath<Self, UUID, TodoAction>(
        embed: Action.todo(id:action:),
        extract: { action in
          guard case let .todo(id, childAction) = action else { return nil }
          return (id, childAction)
        }
      )
    }

    enum TodoAction: Equatable, Sendable {
      case rename(String)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      switch action {
      case .todo(let id, .rename(let title)):
        state.routedActions.append("todo:\(id)")
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          return .none
        }
        state.todos[index].title = title
        return .none

      case .remove(let id):
        state.todos.removeAll { $0.id == id }
        return .none
      }
    }
  }

  @main
  struct StaleScopeProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_STALE_SCOPE_SCENARIO"] {
      case "parent-released":
        let scoped:
          ScopedStore<ParentReleasedFeature, ParentReleasedFeature.Child, ParentReleasedFeature.ChildAction> =
            {
              let store = Store(reducer: ParentReleasedFeature(), initialState: .init())
              return store.scope(state: \.child, action: ParentReleasedFeature.Action.childCasePath)
            }()
        _ = scoped.state.value

      case "collection-entry-removed":
        let store = Store(reducer: CollectionRemovedFeature(), initialState: .init())
        let targetID = store.state.todos[0].id
        let row = store.scope(
          collection: \.todos,
          action: CollectionRemovedFeature.Action.todoActionPath
        )[0]
        store.send(.remove(id: targetID))
        row.send(.rename("Updated"))

      case "selected-parent-released":
        let selected: SelectedStore<Int> = {
          let store = Store(reducer: ParentReleasedFeature(), initialState: .init())
          return store.select(\.child.value)
        }()
        _ = selected.value

      default:
        fatalError("Unknown stale scope scenario")
      }
    }
  }
  """#

private let phaseMapCrashHarnessSource = #"""
  import Foundation

  struct CrashPhaseMutationFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
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

    static let phaseMap = PhaseMap(\State.phase) {
      From(.idle) {
        On(Action.load, to: .loading)
      }
      From(.loading) {
        On(Self.loadedCasePath, to: .loaded)
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
          state.values = values
          return .none
        }
      }
      .phaseMap(map)
      .reduce(into: &state, action: action)
    }
  }

  struct CrashInvalidTargetFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
        case failed
        case idle
        case loaded
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

    static let phaseMap = PhaseMap(\State.phase) {
      From(.failed) {
        On(Self.attemptRecoverCasePath, targets: [.idle, .loaded]) { _, shouldRecover in
          shouldRecover ? .unexpected : nil
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

  @main
  struct PhaseMapCrashProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_PHASEMAP_CRASH_SCENARIO"] {
      case "direct-mutation-crash":
        let store = Store(reducer: CrashPhaseMutationFeature(), initialState: .init())
        store.send(.load)

      case "undeclared-target-crash":
        let store = Store(reducer: CrashInvalidTargetFeature(), initialState: .init())
        store.send(.attemptRecover(true))

      default:
        fputs("Unknown PhaseMap crash scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#

private let phaseMapReleaseHarnessSource = #"""
  import Foundation

  struct ReleasePhaseMutationFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
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

    static let phaseMap = PhaseMap(\State.phase) {
      From(.idle) {
        On(Action.load, to: .loading)
      }
      From(.loading) {
        On(Self.loadedCasePath, to: .loaded)
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

  struct ReleaseInvalidTargetFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
        case failed
        case idle
        case loaded
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

    static let phaseMap = PhaseMap(\State.phase) {
      From(.failed) {
        On(Self.attemptRecoverCasePath, targets: [.idle, .loaded]) { _, shouldRecover in
          shouldRecover ? .unexpected : nil
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

  @main
  struct PhaseMapReleaseProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_PHASEMAP_RELEASE_SCENARIO"] {
      case "direct-mutation-restore":
        let store = Store(reducer: ReleasePhaseMutationFeature(), initialState: .init())
        store.send(.load)
        guard store.state.phase == .loading else {
          fputs("Expected load to restore the previous phase and apply the declared loading transition\n", stderr)
          Foundation.exit(1)
        }

        store.send(.loaded([1, 2, 3]))
        guard store.state.phase == .loaded, store.state.values == [1, 2, 3] else {
          fputs("Expected loaded payload to preserve reducer work and then transition to .loaded\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      case "undeclared-target-noop":
        let store = Store(reducer: ReleaseInvalidTargetFeature(), initialState: .init())
        store.send(.attemptRecover(true))
        guard store.state.phase == .failed, store.state.log == ["recover"] else {
          fputs("Expected undeclared dynamic target to keep the previous phase while preserving reducer work\n", stderr)
          Foundation.exit(1)
        }

        store.send(.attemptRecover(false))
        guard store.state.phase == .failed, store.state.log == ["recover", "skip"] else {
          fputs("Expected nil guard result to keep the previous phase and append reducer work\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      default:
        fputs("Unknown PhaseMap release scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#

private let staleScopedStoreReleaseHarnessSource = #"""
  import Foundation

  struct ReleaseParentReleasedFeature: Reducer {
    struct Child: Equatable, Sendable {
      var value = 42
    }

    struct State: Equatable, Sendable {
      var child = Child()
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case noop
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      .none
    }
  }

  struct ReleaseCollectionRemovedFeature: Reducer {
    struct Todo: Identifiable, Equatable, Sendable {
      let id: UUID
      var title: String
    }

    struct State: Equatable, Sendable {
      var todos: [Todo] = [
        Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "One")
      ]
      var routedActions: [String] = []
    }

    enum Action: Equatable, Sendable {
      case todo(id: UUID, action: TodoAction)
      case remove(id: UUID)

      static let todoActionPath = CollectionActionPath<Self, UUID, TodoAction>(
        embed: Action.todo(id:action:),
        extract: { action in
          guard case let .todo(id, childAction) = action else { return nil }
          return (id, childAction)
        }
      )
    }

    enum TodoAction: Equatable, Sendable {
      case rename(String)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      switch action {
      case .todo(let id, .rename(let title)):
        state.routedActions.append("todo:\(id)")
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          return .none
        }
        state.todos[index].title = title
        return .none

      case .remove(let id):
        state.todos.removeAll { $0.id == id }
        return .none
      }
    }
  }

  @main
  struct StaleScopeReleaseProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_STALE_SCOPE_RELEASE_SCENARIO"] {
      case "parent-released":
        let scoped:
          ScopedStore<
            ReleaseParentReleasedFeature,
            ReleaseParentReleasedFeature.Child,
            ReleaseParentReleasedFeature.ChildAction
          > = {
            let store = Store(
              reducer: ReleaseParentReleasedFeature(), initialState: .init())
            return store.scope(
              state: \.child,
              action: ReleaseParentReleasedFeature.Action.childCasePath
            )
          }()
        // Parent store is now released. Release builds must return the
        // cached child state instead of aborting the process.
        let cached = scoped.state
        guard cached.value == 42 else {
          fputs("Expected cached ScopedStore value 42, got \(cached.value)\n", stderr)
          Foundation.exit(1)
        }
        // Sending after parent release must be a silent no-op.
        scoped.send(.noop)
        print("ok")

      case "collection-entry-removed":
        let store = Store(
          reducer: ReleaseCollectionRemovedFeature(), initialState: .init())
        let targetID = store.state.todos[0].id
        let row = store.scope(
          collection: \.todos,
          action: ReleaseCollectionRemovedFeature.Action.todoActionPath
        )[0]
        store.send(.remove(id: targetID))
        // Both read and write after the entry is removed must tolerate the
        // lifecycle race without aborting.
        row.send(.rename("Updated"))
        let cached = row.state
        guard cached.id == targetID, cached.title == "One" else {
          fputs("Expected cached removed row state, got \(cached)\n", stderr)
          Foundation.exit(1)
        }
        guard store.state.todos.isEmpty, store.state.routedActions.isEmpty else {
          fputs("Expected stale row send to be a no-op, got \(store.state)\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      case "selected-parent-released":
        let selected: SelectedStore<Int> = {
          let store = Store(
            reducer: ReleaseParentReleasedFeature(), initialState: .init())
          return store.select(\.child.value)
        }()
        // Release builds must return the cached projected value instead of
        // aborting.
        let cachedValue = selected.value
        guard cachedValue == 42 else {
          fputs(
            "Expected cached SelectedStore value 42, got \(cachedValue)\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      default:
        fputs("Unknown stale scope release scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#
