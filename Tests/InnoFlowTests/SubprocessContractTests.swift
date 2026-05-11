// MARK: - SubprocessContractTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

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

  @Test(
    "Stale SelectedStore exposes nil optionalValue after parent release in release-like execution"
  )
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
