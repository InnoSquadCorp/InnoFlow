import SwiftIfConfig
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

/// Runs SwiftSyntax macro assertions through Swift Testing's failure channel.
///
/// `SwiftSyntaxMacrosTestSupport.assertMacroExpansion` reports with `XCTFail`.
/// Calling that XCTest-only entry point from a Swift Testing test records an API
/// misuse warning instead of a reliable test failure, so this target uses the
/// generic assertion engine and bridges every mismatch to `Issue.record`.
func assertSwiftTestingMacroExpansion(
  _ originalSource: String,
  expandedSource expectedExpandedSource: String,
  diagnostics: [DiagnosticSpec] = [],
  macros: [String: any Macro.Type],
  applyFixIts: [String]? = nil,
  fixedSource expectedFixedSource: String? = nil,
  testModuleName: String = "TestModule",
  testFileName: String = "test.swift",
  indentationWidth: Trivia = .spaces(4),
  buildConfiguration: (any BuildConfiguration)? = nil,
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) {
  let macroSpecs = macros.mapValues { MacroSpec(type: $0) }
  SwiftSyntaxMacrosGenericTestSupport.assertMacroExpansion(
    originalSource,
    expandedSource: expectedExpandedSource,
    diagnostics: diagnostics,
    macroSpecs: macroSpecs,
    applyFixIts: applyFixIts,
    fixedSource: expectedFixedSource,
    testModuleName: testModuleName,
    testFileName: testFileName,
    indentationWidth: indentationWidth,
    buildConfiguration: buildConfiguration,
    failureHandler: { failure in
      Issue.record(
        Comment(rawValue: failure.message),
        sourceLocation: SourceLocation(
          fileID: failure.location.fileID,
          filePath: failure.location.filePath,
          line: failure.location.line,
          column: failure.location.column
        )
      )
    },
    fileID: fileID,
    filePath: filePath,
    line: line,
    column: column
  )
}
