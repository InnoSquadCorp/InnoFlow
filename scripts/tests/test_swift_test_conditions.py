"""Compiler-specific declaration inventory, independent of execution counts."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swift_test_conditions import active, compiler_version, host_counts, runtime_selection


class SwiftTestConditionsTests(unittest.TestCase):
    def test_reviewed_compiler_identity_requires_actual_version_output(self):
        for output, expected in (("Swift version 6.3 (swift-6.3-RELEASE)", "6.3"),
                                 ("Apple Swift version 6.4.1 (swiftlang-fixture); Xcode 27", "6.4")):
            self.assertEqual(compiler_version(output), expected)
        for output in (None, "6.4", "Xcode 27", "Swift version 6.5", "Swift version 6.40",
                       "Swift version 6.4-development", "Swift version 6.3\nSwift version 6.4"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                compiler_version(output)

    def test_host_counts_include_parameterized_declaration_once_and_full_uses_64(self):
        tests = [{"target": "InnoFlowTests", "identifier": identifier,
                  "conditionalContexts": conditions} for identifier, conditions in (
            ("EffectTimingBaselineGate/timing()", []), ("CommonTests/parameterized(value:)", []),
            ("CompiledHarnessCacheTests/preservesProcessIsolation()", ["#if os(macOS) || os(Linux)"]),
            ("ConditionalTests/didSet()", ["#if compiler(>=6.4)"]))]
        self.assertEqual(host_counts({"tests": tests}), {"6.3": 3, "6.4": 4, "full-principle": 9})
        tests[-1]["conditionalContexts"] = ["#if os(macOS)"]
        with self.assertRaises(ValueError):
            host_counts({"tests": tests})

    def test_nested_unknown_or_alternative_branches_fail_closed(self):
        for contexts in (["#else "], ["#elseif compiler(>=6.4)"],
                         ["#if compiler(>=6.4)", "#if CUSTOM"], ["#if swift(>=6.4)"],
                         ["#if os(macOS) || os(Linux)"], None, {}):
            with self.subTest(contexts=contexts), self.assertRaises(ValueError):
                active(contexts, "6.4", host=True, identifier="Other/test()")

    def test_runtime_preserves_union_and_selects_diagnostics_exactly(self):
        inventory = {"expectedTestIdentifiers": ["A/common()", "B/new()"],
                     "expectedFailureTestIdentifiers": ["B/new()"],
                     "conditionalContextsByIdentifier": {"B/new()": ["#if compiler(>=6.4)"]}}
        old = runtime_selection(inventory, "Swift version 6.3")
        new = runtime_selection(inventory, "Swift version 6.4")
        self.assertEqual(old["expectedTestIdentifiers"], ["A/common()"])
        self.assertEqual(old["expectedFailureTestIdentifiers"], [])
        self.assertEqual(new["expectedTestIdentifiers"], inventory["expectedTestIdentifiers"])
        self.assertEqual(new["expectedFailureTestIdentifiers"], ["B/new()"])
        self.assertEqual(len(inventory["expectedTestIdentifiers"]), 2)


if __name__ == "__main__":
    unittest.main()
