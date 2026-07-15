// MARK: - StorePresentationTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftUI
import Testing

@testable import InnoFlowCore
@testable import InnoFlowSwiftUI

@Suite("Store presentation SwiftUI integration", .serialized)
@MainActor
struct StorePresentationTests {
  @Test("presentation binding reads live optional state")
  func presentationBindingReadsLiveState() {
    let store = Store(
      reducer: PresentationFeature(),
      initialState: .init()
    )
    let binding = innoFlowOptionalPresentationBinding(
      store: store,
      state: \.child,
      onDismiss: { .dismiss }
    )

    #expect(binding.wrappedValue == false)

    store.send(.present(7))
    #expect(binding.wrappedValue == true)

    store.send(.clear)
    #expect(binding.wrappedValue == false)
  }

  @Test("presentation binding ignores true writes")
  func presentationBindingIgnoresTrueWrites() {
    let store = Store(
      reducer: PresentationFeature(),
      initialState: .init(child: .init(value: 1))
    )
    let binding = innoFlowOptionalPresentationBinding(
      store: store,
      state: \.child,
      onDismiss: { .dismiss }
    )

    binding.wrappedValue = true

    #expect(store.state.child == .init(value: 1))
    #expect(store.state.dismissCount == 0)
  }

  @Test("presentation binding ignores false writes after state is already nil")
  func presentationBindingIgnoresFalseWritesWhenNil() {
    let store = Store(
      reducer: PresentationFeature(),
      initialState: .init()
    )
    let binding = innoFlowOptionalPresentationBinding(
      store: store,
      state: \.child,
      onDismiss: { .dismiss }
    )

    binding.wrappedValue = false

    #expect(store.state.child == nil)
    #expect(store.state.dismissCount == 0)
  }

  @Test("presentation binding does not resend dismissal after reducer clears state")
  func presentationBindingDoesNotResendAfterStateClears() {
    let store = Store(
      reducer: PresentationFeature(),
      initialState: .init(child: .init(value: 1))
    )
    let binding = innoFlowOptionalPresentationBinding(
      store: store,
      state: \.child,
      onDismiss: { .dismiss }
    )

    binding.wrappedValue = false
    binding.wrappedValue = false

    #expect(store.state.child == nil)
    #expect(store.state.dismissCount == 1)
  }

  @Test("sheet and navigation helpers compile with generic optional state")
  func presentationHelpersCompile() {
    let store = Store(
      reducer: PresentationFeature(),
      initialState: .init(child: .init(value: 1))
    )

    _ = EmptyView().innoFlowSheet(
      store: store,
      state: \.child,
      onDismiss: { .dismiss },
      content: { child in
        Text(verbatim: "\(child.value)")
      }
    )

    _ = EmptyView().innoFlowNavigationDestination(
      store: store,
      state: \.child,
      onDismiss: { .dismiss },
      content: { child in
        Text(verbatim: "\(child.value)")
      }
    )
  }
}

private struct PresentationFeature: Reducer {
  struct Child: Equatable, Sendable {
    let value: Int
  }

  struct State: Equatable, Sendable {
    var child: Child?
    var dismissCount = 0
  }

  enum Action: Equatable, Sendable {
    case present(Int)
    case clear
    case dismiss
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .present(let value):
      state.child = .init(value: value)

    case .clear:
      state.child = nil

    case .dismiss:
      state.child = nil
      state.dismissCount += 1
    }

    return .none
  }
}
