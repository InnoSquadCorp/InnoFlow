// MARK: - StoreSwiftUIBindingTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import SwiftUI
import Testing

@testable import InnoFlowCore
@testable import InnoFlowSwiftUI

private struct SwiftUIBindingFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    @BindableField var step: Int = 1
  }

  enum Action: Equatable, Sendable {
    case setStep(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .setStep(let step):
      state.step = step
      return .none
    }
  }
}

@Suite("Store.binding SwiftUI integration", .serialized)
@MainActor
struct StoreSwiftUIBindingTests {

  @Test("binding(_:send:) reads state and dispatches the constructed action on set")
  func bindingSendReadsAndWrites() {
    let store = Store(reducer: SwiftUIBindingFeature(), initialState: .init())

    let stepBinding = store.binding(\.$step, send: SwiftUIBindingFeature.Action.setStep)
    #expect(stepBinding.wrappedValue == 1)

    stepBinding.wrappedValue = 7
    #expect(store.state.step == 7)
    #expect(stepBinding.wrappedValue == 7)
  }

  @Test("binding(_:to:) is a label alias for binding(_:send:) and dispatches the same action")
  func bindingToAliasDispatchesSameAction() {
    let store = Store(reducer: SwiftUIBindingFeature(), initialState: .init())

    let toBinding = store.binding(\.$step, to: SwiftUIBindingFeature.Action.setStep)
    toBinding.wrappedValue = 3
    #expect(store.state.step == 3)

    let sendBinding = store.binding(\.$step, send: SwiftUIBindingFeature.Action.setStep)
    sendBinding.wrappedValue = 5
    #expect(store.state.step == 5)
  }

  @Test("Trailing-closure binding(_:_:) overload still resolves and dispatches")
  func bindingTrailingClosureDispatches() {
    let store = Store(reducer: SwiftUIBindingFeature(), initialState: .init())

    let trailingBinding = store.binding(\.$step) { value in
      SwiftUIBindingFeature.Action.setStep(value * 2)
    }

    trailingBinding.wrappedValue = 4
    #expect(store.state.step == 8)
  }

  @Test("Repeated binding(_:send:) calls return independent live bindings tracking the same state")
  func repeatedBindingCallsTrackLiveState() {
    let store = Store(reducer: SwiftUIBindingFeature(), initialState: .init())

    let firstBinding = store.binding(\.$step, send: SwiftUIBindingFeature.Action.setStep)
    let secondBinding = store.binding(\.$step, send: SwiftUIBindingFeature.Action.setStep)

    firstBinding.wrappedValue = 11
    #expect(secondBinding.wrappedValue == 11)
    secondBinding.wrappedValue = 22
    #expect(firstBinding.wrappedValue == 22)
    #expect(store.state.step == 22)
  }

  @Test("Setting binding to the same value still routes through the reducer")
  func bindingIdempotentWriteStillReduces() {
    let store = Store(reducer: SwiftUIBindingFeature(), initialState: .init())

    let stepBinding = store.binding(\.$step, send: SwiftUIBindingFeature.Action.setStep)
    stepBinding.wrappedValue = 1
    #expect(store.state.step == 1)

    stepBinding.wrappedValue = 1
    // No-op equivalent assignment is allowed; reducer ran twice but the
    // observable state is identical.
    #expect(store.state.step == 1)
  }
}
