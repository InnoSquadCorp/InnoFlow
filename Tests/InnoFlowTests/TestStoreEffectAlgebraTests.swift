// MARK: - TestStoreEffectAlgebraTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI
import Testing
import os

@testable import InnoFlow
@testable import InnoFlowTesting

// MARK: - TestStore Effect Algebra Tests

@Suite("TestStore Effect Algebra Tests", .serialized)
@MainActor
struct TestStoreEffectAlgebraTests {
  @Test("ThrottleStateMap.clearState cancels trailing task and clears pending state")
  @MainActor
  func throttleStateMapClearState() {
    let map = ThrottleStateMap<CounterFeature.Action>()
    let id = AnyEffectID(StaticEffectID("throttle-clear-state"))
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

  @Test("ThrottleStateMap.finishState clears current state without cancelling current task")
  @MainActor
  func throttleStateMapFinishState() {
    let map = ThrottleStateMap<CounterFeature.Action>()
    let id = AnyEffectID(StaticEffectID("throttle-finish-state"))
    let task = Task<Void, Never> {
      try? await Task.sleep(for: .seconds(5))
    }

    map.setWindowEnd(ContinuousClock().now, for: id)
    map.storePending(.send(.increment), context: nil, for: id)
    let generation = map.nextGeneration(for: id)
    map.setTrailingTask(task, for: id)

    #expect(map.finishState(for: id, generation: generation + 1) == false)
    #expect(map.pending(for: id) != nil)
    #expect(task.isCancelled == false)

    #expect(map.finishState(for: id, generation: generation) == true)
    #expect(map.windowEnd(for: id) == nil)
    #expect(map.pending(for: id) == nil)
    #expect(map.generation(for: id) == nil)
    #expect(task.isCancelled == false)

    let nextGeneration = map.nextGeneration(for: id)
    #expect(nextGeneration > generation)

    task.cancel()
  }

  @Test("ThrottleStateMap.clearAll cancels all trailing tasks and clears stored state")
  @MainActor
  func throttleStateMapClearAll() {
    let map = ThrottleStateMap<CounterFeature.Action>()
    let firstID = AnyEffectID(StaticEffectID("throttle-clear-all-1"))
    let secondID = AnyEffectID(StaticEffectID("throttle-clear-all-2"))
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
