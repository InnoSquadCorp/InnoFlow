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

  @Test("CollectionActionPath copies share opaque identity")
  func collectionActionPathCopiesShareIdentity() {
    let original = IdentityAction.rowActionPath
    let copy = original

    #expect(original.identity === copy.identity)
  }

  @Test("Independently constructed CollectionActionPaths have distinct identities")
  func independentlyConstructedCollectionActionPathsHaveDistinctIdentities() {
    let first = makeRowActionPath()
    let second = makeRowActionPath()

    #expect(first.identity !== second.identity)
  }

  @Test("Identity does not change CollectionActionPath embedding and extraction")
  func identityPreservesCollectionActionPathBehavior() {
    let path = makeRowActionPath()

    #expect(path.embed(42, 7) == .row(id: 42, action: 7))
    #expect(path.extract(.row(id: 3, action: 9))?.0 == 3)
    #expect(path.extract(.row(id: 3, action: 9))?.1 == 9)
    #expect(path.extract(.other) == nil)
  }
}

private enum IdentityAction: Equatable, Sendable {
  case value(Int)
  case row(id: Int, action: Int)
  case other

  static let valueCasePath = makeValueCasePath()
  static let rowActionPath = makeRowActionPath()
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

private func makeRowActionPath() -> CollectionActionPath<IdentityAction, Int, Int> {
  CollectionActionPath(
    embed: { id, action in
      .row(id: id, action: action)
    },
    extract: { action in
      guard case .row(let id, let childAction) = action else { return nil }
      return (id, childAction)
    }
  )
}
