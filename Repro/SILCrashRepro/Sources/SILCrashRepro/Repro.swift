// SILCrashRepro/Repro.swift
//
// Minimal reproduction for a SIL EarlyPerfInliner crash on Swift 6.3
// (`swift-6.3-RELEASE` / `swift-6.3.*` nightly toolchains).
//
// Symptom (at build time, `-c release`):
//   Swift trap: SIL EarlyPerfInliner segfault inside
//   isCallerAndCalleeLayoutConstraintsCompatible while visiting
//   a `@MainActor isolated deinit` on a generic class that stores
//   result-builder-composed value types.
//
// Reproduction:
//   swift build --package-path Repro/SILCrashRepro -c release
//
// `-Onone` (debug) build succeeds.

import Foundation

// MARK: - Reducer protocol (mirrors InnoFlow shape)

public protocol Repro_Reducer<State, Action> {
  associatedtype State
  associatedtype Action
  func reduce(into state: inout State, action: Action) -> Repro_Effect<Action>
}

public struct Repro_Effect<Action>: Sendable where Action: Sendable {
  public let token: UInt64
  public init(token: UInt64 = 0) { self.token = token }
  public static var none: Self { .init(token: 0) }
}

// MARK: - Builder-emitted composition types (mirrors ReducerBuilder shape)

public struct Repro_Sequence<R1: Repro_Reducer, R2: Repro_Reducer>: Repro_Reducer
where R1.State == R2.State, R1.Action == R2.Action, R1.Action: Sendable {
  public typealias State = R1.State
  public typealias Action = R1.Action

  @usableFromInline let r1: R1
  @usableFromInline let r2: R2

  public init(_ r1: R1, _ r2: R2) {
    self.r1 = r1
    self.r2 = r2
  }

  @inlinable
  public func reduce(into state: inout State, action: Action) -> Repro_Effect<Action> {
    _ = r1.reduce(into: &state, action: action)
    return r2.reduce(into: &state, action: action)
  }
}

public struct Repro_Optional<Wrapped: Repro_Reducer>: Repro_Reducer where Wrapped.Action: Sendable {
  public typealias State = Wrapped.State
  public typealias Action = Wrapped.Action

  @usableFromInline let wrapped: Wrapped?
  public init(_ wrapped: Wrapped?) { self.wrapped = wrapped }

  @inlinable
  public func reduce(into state: inout State, action: Action) -> Repro_Effect<Action> {
    wrapped?.reduce(into: &state, action: action) ?? .none
  }
}

// MARK: - Store with @MainActor isolated deinit storing the composed reducer

@MainActor
public final class Repro_Store<R: Repro_Reducer> where R.Action: Sendable {
  public private(set) var state: R.State
  private let reducer: R
  private let token = UUID()

  public init(reducer: R, initialState: R.State) {
    self.reducer = reducer
    self.state = initialState
  }

  public func send(_ action: R.Action) {
    _ = reducer.reduce(into: &state, action: action)
  }

  // The combination that triggers the crash on Swift 6.3 release builds:
  //   * generic class (`R: Repro_Reducer`)
  //   * `@MainActor isolated deinit`
  //   * reducer field holds builder-emitted composition types
  //     (`Repro_Sequence<Repro_Sequence<..., Repro_Optional<...>>>`)
  //
  // Applying `@_optimize(none)` to this deinit is the workaround used in
  // InnoFlow.
  isolated deinit {
    _ = reducer
    _ = token
  }
}

// MARK: - Example leaf reducer

public struct Repro_Leaf: Repro_Reducer {
  public struct State: Sendable {
    public var count: Int = 0
    public init() {}
  }

  public enum Action: Sendable {
    case tick
  }

  public init() {}

  @inlinable
  public func reduce(into state: inout State, action: Action) -> Repro_Effect<Action> {
    switch action {
    case .tick:
      state.count &+= 1
      return .none
    }
  }
}

// MARK: - Public entry point that forces instantiation of the composition

@MainActor
public func repro_make() -> Repro_Store<some Repro_Reducer<Repro_Leaf.State, Repro_Leaf.Action>> {
  let composed = Repro_Sequence(
    Repro_Leaf(),
    Repro_Sequence(
      Repro_Leaf(),
      Repro_Optional(Repro_Leaf() as Repro_Leaf?)
    )
  )
  return Repro_Store(reducer: composed, initialState: Repro_Leaf.State())
}
