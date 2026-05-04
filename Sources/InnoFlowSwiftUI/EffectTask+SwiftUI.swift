// MARK: - EffectTask+SwiftUI.swift
// InnoFlow - SwiftUI integration
// Copyright © 2025 InnoSquad. All rights reserved.

public import InnoFlow
public import SwiftUI

extension EffectTask {
  /// Applies animation to state changes caused by actions emitted from this effect.
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
