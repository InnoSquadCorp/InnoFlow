// MARK: - TestStoreDefaultsTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing

@testable import InnoFlowCore
@testable import InnoFlowTesting

private struct DefaultsFeature: Reducer {
  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: Hashable, Sendable {
      case idle
      case done
    }

    var phase: Phase = .idle
  }

  enum Action: Equatable, Sendable { case noop }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    .none
  }
}

/// Resolves one raw override and returns the deadline together with every
/// diagnostic the resolver wanted to print.
private func resolve(_ rawValue: String?) -> (timeout: Duration, diagnostics: [String]) {
  var environment: [String: String] = [:]
  environment[TestStoreDefaults.effectTimeoutEnvironmentKey] = rawValue
  var diagnostics: [String] = []
  let timeout = TestStoreDefaults.resolveEffectTimeout(environment: environment) {
    diagnostics.append($0)
  }
  return (timeout, diagnostics)
}

@Suite("TestStore deadline defaults", .timeLimit(.minutes(5)))
struct TestStoreDefaultsTests {
  @Test("The default effect deadline is one second without an override")
  func defaultEffectTimeoutIsOneSecond() {
    let resolved = resolve(nil)

    #expect(resolved.timeout == .seconds(1))
    #expect(resolved.diagnostics.isEmpty)
    #expect(TestStoreDefaults.resolveEffectTimeout(environment: [:]) == .seconds(1))
  }

  @Test(
    "A positive number of seconds overrides the default effect deadline",
    arguments: [
      ("10", Duration.seconds(10)),
      ("2.5", Duration.milliseconds(2_500)),
      ("0.25", Duration.milliseconds(250)),
      ("86400", Duration.seconds(86_400)),
    ]
  )
  func environmentOverridesEffectTimeout(rawValue: String, expected: Duration) {
    let resolved = resolve(rawValue)

    #expect(resolved.timeout == expected)
    #expect(resolved.diagnostics.isEmpty)
  }

  @Test(
    "Whitespace around an override is ignored",
    arguments: [
      ("10 ", Duration.seconds(10)),
      (" 10", Duration.seconds(10)),
      ("\t2.5\n", Duration.milliseconds(2_500)),
    ]
  )
  func surroundingWhitespaceIsAccepted(rawValue: String, expected: Duration) {
    let resolved = resolve(rawValue)

    #expect(resolved.timeout == expected)
    #expect(resolved.diagnostics.isEmpty)
  }

  @Test("An empty override counts as unset", arguments: ["", " ", "\t\n"])
  func emptyOverrideIsUnset(rawValue: String) {
    let resolved = resolve(rawValue)

    #expect(resolved.timeout == .seconds(1))
    #expect(resolved.diagnostics.isEmpty)
  }

  @Test(
    "An unusable override keeps the one-second default and says so once",
    arguments: ["abc", "0", "-3", "nan", "-inf", "10s", "1,5", "1 0"]
  )
  func unusableOverrideFallsBackAndSaysSo(rawValue: String) {
    let resolved = resolve(rawValue)

    #expect(resolved.timeout == .seconds(1))
    #expect(resolved.diagnostics.count == 1)
    #expect(
      resolved.diagnostics.first?.contains(TestStoreDefaults.effectTimeoutEnvironmentKey) == true)
    #expect(resolved.diagnostics.first?.contains("\"\(rawValue)\"") == true)
  }

  @Test(
    "An absurdly large override is clamped instead of trapping, and says so once",
    arguments: ["86401", "1e16", "1e300", "1e400", "inf", "infinity"]
  )
  func hugeOverrideIsClamped(rawValue: String) {
    let resolved = resolve(rawValue)

    #expect(resolved.timeout == TestStoreDefaults.maximumEffectTimeout)
    #expect(resolved.diagnostics.count == 1)
    #expect(
      resolved.diagnostics.first?.contains(TestStoreDefaults.effectTimeoutEnvironmentKey) == true)
    #expect(resolved.diagnostics.first?.contains("\"\(rawValue)\"") == true)
  }

  @MainActor
  @Test("Every initializer uses the process default unless it states a deadline")
  func initializersUseProcessDefaultUnlessStated() {
    // The process default comes from this process's real environment. When
    // `INNOFLOW_TESTSTORE_EFFECT_TIMEOUT` is unset it equals the built-in one
    // second, and this test then cannot tell "reads the default" from "hard
    // codes one second"; it discriminates in a run that sets the variable,
    // such as the documented scaled parallel run.
    let processDefault = TestStoreDefaults.resolveEffectTimeout(
      environment: ProcessInfo.processInfo.environment
    ) { _ in }
    #expect(TestStoreDefaults.effectTimeout == processDefault)

    let map: PhaseMap<DefaultsFeature.State, DefaultsFeature.Action, DefaultsFeature.State.Phase> =
      PhaseMap(\.phase) {
        From(.idle) {
          On(.noop, to: .done)
        }
      }
    let recorder = PhaseCoverageRecorder(map)
    let reducer = DefaultsFeature()
    let stated = Duration.milliseconds(40)

    let implicit = [
      TestStore(reducer: reducer, initialState: .init()).effectTimeout,
      TestStore(reducer: reducer).effectTimeout,
      TestStore(reducer: reducer, initialState: .init(), phaseCoverage: recorder).effectTimeout,
      TestStore(reducer: reducer, phaseCoverage: recorder).effectTimeout,
    ]
    let explicit = [
      TestStore(reducer: reducer, initialState: .init(), effectTimeout: stated).effectTimeout,
      TestStore(reducer: reducer, effectTimeout: stated).effectTimeout,
      TestStore(
        reducer: reducer, initialState: .init(), phaseCoverage: recorder, effectTimeout: stated
      ).effectTimeout,
      TestStore(reducer: reducer, phaseCoverage: recorder, effectTimeout: stated).effectTimeout,
    ]

    #expect(implicit == Array(repeating: processDefault, count: 4))
    #expect(explicit == Array(repeating: stated, count: 4))
  }
}
