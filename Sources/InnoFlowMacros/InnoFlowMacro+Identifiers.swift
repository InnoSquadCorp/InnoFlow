// MARK: - InnoFlowMacro+Identifiers.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import SwiftSyntax

extension InnoFlowMacro {
  /// Comparisons use the identifier's meaning, never its optional source backticks.
  static func logicalIdentifier(_ token: TokenSyntax) -> String {
    Identifier(token)?.name ?? logicalIdentifier(token.text)
  }

  static func logicalIdentifier(_ spelling: String) -> String {
    if spelling.hasPrefix("`"), spelling.hasSuffix("`"), spelling.count >= 2 {
      return String(spelling.dropFirst().dropLast())
    }
    return spelling
  }

  /// Preserve the public naming rule: strip exactly one leading underscore.
  /// In particular, spaces and punctuation are not replaced or collapsed.
  static func generatedPathBaseName(from caseName: TokenSyntax) -> String {
    let name = logicalIdentifier(caseName)
    return name.hasPrefix("_") && name.count > 1 ? String(name.dropFirst()) : name
  }

  /// A source token already carries any escaping required by its spelling,
  /// including keywords, raw identifiers, and associated-value labels.
  static func identifierSource(_ token: TokenSyntax, asArgumentLabel: Bool = false) -> String {
    // Argument labels admit keywords unescaped. Retaining redundant keyword
    // backticks there introduces compiler warnings into otherwise valid input.
    if asArgumentLabel {
      return generatedIdentifierSource(logicalIdentifier(token))
    }
    return token.text
  }

  /// Generated names have a non-keyword prefix or suffix; argument labels also
  /// admit keywords. Keep the historical
  /// spelling of simple ASCII names, and quote everything else conservatively.
  /// This also handles an underscore-stripped name beginning with a digit.
  static func generatedIdentifierSource(_ logicalName: String) -> String {
    func isHead(_ byte: UInt8) -> Bool {
      byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }
    let bytes = logicalName.utf8
    if let first = bytes.first, isHead(first),
      bytes.dropFirst().allSatisfy({ isHead($0) || (48...57).contains($0) })
    {
      return logicalName
    }
    return "`\(logicalName)`"
  }
}
