// MARK: - ActionPathIdentityTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCore

@Suite("Action path identity")
struct ActionPathIdentityTests {
  @Test("CasePath copies share opaque identity")
  func casePathCopiesShareIdentity() {
    let original = IdentityAction.valueCasePath
    let copy = original

    #expect(original.identity === copy.identity)
  }

  @Test("Independently constructed CasePaths have distinct identities")
  func independentlyConstructedCasePathsHaveDistinctIdentities() {
    let first = makeValueCasePath()
    let second = makeValueCasePath()

    #expect(first.identity !== second.identity)
  }

  @Test("Identity does not change CasePath embedding and extraction")
  func identityPreservesCasePathBehavior() {
    let path = makeValueCasePath()

    #expect(path.embed(42) == .value(42))
    #expect(path.extract(.value(7)) == 7)
    #expect(path.extract(.other) == nil)
  }
}

private enum IdentityAction: Equatable, Sendable {
  case value(Int)
  case other

  static let valueCasePath = makeValueCasePath()
}

private func makeValueCasePath() -> CasePath<IdentityAction, Int> {
  CasePath(
    embed: IdentityAction.value,
    extract: { action in
      guard case .value(let value) = action else { return nil }
      return value
    }
  )
}
