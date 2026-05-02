// MARK: - InnoFlowMacro+TriviaHelpers.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntax

extension Trivia {
  /// Returns just the indentation portion (trailing spaces/tabs) of the
  /// trivia that follows the last newline. Used to inherit enum member
  /// indentation when synthesising a new `case` via Fix-It.
  var firstIndentation: Trivia {
    var indent: [TriviaPiece] = []
    for piece in pieces.reversed() {
      switch piece {
      case .newlines, .carriageReturns, .carriageReturnLineFeeds:
        return Trivia(pieces: indent.reversed())
      case .spaces, .tabs:
        indent.append(piece)
      default:
        indent.removeAll()
      }
    }
    return Trivia(pieces: indent.reversed())
  }
}
