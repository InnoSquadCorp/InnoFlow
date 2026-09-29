// MARK: - EffectTask+SwiftUI.swift
// InnoFlow - SwiftUI integration
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported public import InnoFlowCore
public import SwiftUI

extension ReducerEffect {
  /// Applies animation to state changes caused by actions emitted from this effect.
  ///
  /// Both actions and typed outputs keep their original types and ordering.
  public func animation(_ animation: Animation? = .default) -> Self {
    applyingAnimation(
      .init(description: String(describing: animation)) { updates in
        withAnimation(animation) {
          updates()
        }
      }
    )
  }
}
