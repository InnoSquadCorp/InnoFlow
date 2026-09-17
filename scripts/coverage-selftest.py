#!/usr/bin/env python3
"""Adversarial controls for the release coverage gate; no Swift build required."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("coverage_gate", Path(__file__).with_name("validate-coverage-report.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        source = self.root / "Sources/InnoFlowCore/Store.swift"
        source.parent.mkdir(parents=True)
        source.write_text("// fixture\n")
        self.valid = f"SF:{source}\nDA:1,2\nDA:2,0\nLF:2\nLH:1\nend_of_record\n"
        self.policy = {"schemaVersion": 1, "minimumLineCoverage": 50,
                       "requiredModules": ["InnoFlowCore"]}

    def report(self, source=None):
        return gate.summarize(gate.parse_report(self.valid if source is None else source, self.root))

    def test_valid_and_llvm_unlisted_regions(self):
        gate.check_policy(self.report(), self.policy)
        report = self.report(self.valid.replace("LF:2\nLH:1", "LF:3\nLH:2"))
        self.assertEqual(report["totals"]["foundLines"], 3)
        self.assertEqual(report["modules"]["InnoFlowCore"]["hitLines"], 2)

    def test_malformed_reports_fail(self):
        mutations = ["", self.valid * 2, self.valid.replace("end_of_record", ""),
                     self.valid.replace("LF:2\n", ""), self.valid.replace("LH:1", "LH:3"),
                     self.valid.replace("LH:1", "LH:2"), self.valid.replace("DA:2,0", "DA:1,0"),
                     self.valid.replace("DA:1,2", "DA:0,2"), self.valid.replace("DA:1,2", "DA:1,-1"),
                     self.valid.replace("LF:2", "LF:2\nLF:2"), "LH:1\n" + self.valid,
                     self.valid.replace("DA:1,2\nDA:2,0\n", ""),
                     self.valid.replace("Sources/", "Tests/"), self.valid.replace("Store.swift", "Missing.swift"),
                     self.valid.replace("DA:1,2", "DA:1"), self.valid.replace("LF:2", "LF:nan"),
                     self.valid.replace("LH:1", "UNKNOWN:1\nLH:1")]
        for source in mutations:
            with self.subTest(source=source), self.assertRaises((ValueError, OSError)):
                self.report(source)

    def test_threshold_and_module_omission_fail(self):
        for mutation in [{"minimumLineCoverage": 51}, {"minimumLineCoverage": float("nan")},
                         {"minimumLineCoverage": 0}, {"minimumLineCoverage": True},
                         {"minimumLineCoverage": 101}, {"requiredModules": []},
                         {"requiredModules": ["InnoFlowMacros"]},
                         {"requiredModules": ["InnoFlowCore", "InnoFlowCore"]}]:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                gate.check_policy(self.report(), self.policy | mutation)


class ExporterTests(unittest.TestCase):
    def test_multiple_bundles_and_failure_preserve_previous_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            commands = root / "commands"
            commands.mkdir()
            products = root / "products"
            for name in ("RuntimeTests", "MacroTests"):
                binary = products / f"{name}.xctest/Contents/MacOS/{name}"
                binary.parent.mkdir(parents=True)
                binary.write_text("fixture")
                binary.chmod(0o755)
                os.utime(binary, (100, 100))
            profile = products / "codecov/default.profdata"
            profile.parent.mkdir()
            profile.write_text("fixture")
            os.utime(profile, (200, 200))
            swift = commands / "swift"
            swift.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_PRODUCTS"\n')
            swift.chmod(0o755)
            xcrun = commands / "xcrun"
            xcrun.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_ARGUMENTS"\nprintf "exported\\n"\nexit "${TEST_EXPORT_EXIT:-0}"\n')
            xcrun.chmod(0o755)
            arguments = root / "arguments"
            output = root / "coverage.lcov"
            environment = os.environ | {"PATH": f"{commands}:{os.environ['PATH']}",
                                        "TEST_PRODUCTS": str(products), "TEST_ARGUMENTS": str(arguments)}
            command = ["bash", str(Path(__file__).with_name("generate-coverage-report.sh")), str(output)]
            result = subprocess.run(command, env=environment, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("-object", arguments.read_text())
            self.assertIn("MacroTests.xctest", arguments.read_text())
            self.assertIn("RuntimeTests.xctest", arguments.read_text())
            self.assertEqual(output.read_text(), "exported\n")
            for changes in ({"TEST_EXPORT_EXIT": "42"}, {}):
                if not changes:
                    os.utime(profile, (50, 50))
                result = subprocess.run(command, env=environment | changes, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(output.read_text(), "exported\n")


class RunnerTests(unittest.TestCase):
    def test_exit_propagation_candidate_change_and_fresh_attempts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            scripts = root / "scripts"
            scripts.mkdir()
            commands = root / "commands"
            commands.mkdir()
            shutil.copy(Path(__file__).with_name("run-coverage.sh"), scripts)
            stubs = {
                commands / "swift": 'printf "test output\\n"; exit "${TEST_SWIFT_EXIT:-0}"',
                commands / "python3": 'exit "${TEST_POLICY_EXIT:-0}"',
                commands / "ruby": 'if [ -f "$TEST_SNAPSHOT_MARKER" ] && [ "${TEST_CHANGED:-0}" = 1 ]; then echo changed; else echo candidate; fi; touch "$TEST_SNAPSHOT_MARKER"',
                scripts / "generate-coverage-report.sh": 'printf "LCOV fixture\\n" > "$1"',
            }
            for path, source in stubs.items():
                path.write_text("#!/bin/sh\n" + source + "\n")
                path.chmod(0o755)
            for index, (changes, expected_pass) in enumerate([
                ({}, True), ({"TEST_SWIFT_EXIT": "42"}, False),
                ({"TEST_CHANGED": "1"}, False), ({"TEST_POLICY_EXIT": "1"}, False),
            ]):
                environment = os.environ | {"PATH": f"{commands}:{os.environ['PATH']}",
                                            "TEST_SNAPSHOT_MARKER": str(root / f"snapshot-{index}")} | changes
                before = set((root / ".build/coverage").glob("run.*"))
                result = subprocess.run(["bash", str(scripts / "run-coverage.sh")],
                                        env=environment, capture_output=True)
                self.assertEqual(result.returncode == 0, expected_pass, result.stderr)
                created = set((root / ".build/coverage").glob("run.*")) - before
                self.assertEqual(len(created), 1)
                status = (created.pop() / "status.txt").read_text()
                self.assertEqual(status.startswith("PASS"), expected_pass)


if __name__ == "__main__":
    unittest.main()
