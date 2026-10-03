"""Mutation controls for reviewed discovery and exact focused xcresult evidence."""

import copy
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "focused_runtime", Path(__file__).resolve().parents[1] / "validate-focused-runtime-result.py"
)
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class FocusedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.inventory = {
            "schemaVersion": 1,
            "suites": ["FixtureConsistencyTests", "OtherTests"],
            "expectedTestIdentifiers": [
                "FixtureConsistencyTests/parameterized(value:)", "OtherTests/control()"
            ],
        }
        self.discovery = {"errors": [], "values": [{
            "disabledTests": [], "enabledTests": [
                {"identifier": "InnoFlowTests/" + item}
                for item in self.inventory["expectedTestIdentifiers"]
            ]
        }]}
        self.summary = {"result": "Passed", "totalTestCount": 2,
                        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                        "runtimeWarnings": []}
        self.tests = {"tests": [
            {"nodeType": "Test Case", "nodeIdentifier": item, "result": "Passed"}
            for item in self.inventory["expectedTestIdentifiers"]
        ]}

    def test_complete_discovery_and_results_pass(self):
        self.assertEqual(RUNTIME.validate_discovery(self.inventory, self.discovery)[0], [])
        self.assertEqual(RUNTIME.validate(self.inventory, self.summary, self.tests), ([], 2))

    def test_omitted_empty_disabled_list_keeps_existing_discovery_compatibility(self):
        del self.discovery["values"][0]["disabledTests"]
        self.assertEqual(RUNTIME.validate_discovery(self.inventory, self.discovery)[0], [])

    def test_new_consistency_suite_requires_review(self):
        self.discovery["values"][0]["enabledTests"].append(
            {"identifier": "InnoFlowTests/NewConsistencyTests/regression()"})
        self.assertIn("unreviewed-consistency-suite=NewConsistencyTests",
                      RUNTIME.validate_discovery(self.inventory, self.discovery)[0])

    def test_unrelated_suite_remains_outside_focused_inventory(self):
        self.discovery["values"][0]["enabledTests"].append(
            {"identifier": "InnoFlowTests/UnrelatedTests/other()"})
        self.assertEqual(RUNTIME.validate_discovery(self.inventory, self.discovery)[0], [])

    def test_missing_extra_renamed_duplicate_and_disabled_discovery_fail(self):
        for mode in ("missing", "extra", "renamed", "duplicate", "disabled", "errors"):
            with self.subTest(mode=mode):
                discovery = copy.deepcopy(self.discovery)
                entries = discovery["values"][0]["enabledTests"]
                if mode == "missing":
                    entries.pop()
                elif mode == "extra":
                    entries.append({"identifier": "InnoFlowTests/OtherTests/new()"})
                elif mode == "renamed":
                    entries[0]["identifier"] += "renamed"
                elif mode == "duplicate":
                    entries.append(entries[0])
                elif mode == "disabled":
                    discovery["values"][0]["disabledTests"] = [entries[0]]
                else:
                    discovery["errors"] = ["discovery failed"]
                self.assertTrue(RUNTIME.validate_discovery(self.inventory, discovery)[0])

    def test_missing_runtime_target_and_host_only_macro_target_fail_closed(self):
        for mode in ("only-host-target", "extra-host-target", "missing-target", "malformed"):
            with self.subTest(mode=mode):
                discovery = copy.deepcopy(self.discovery)
                entries = discovery["values"][0]["enabledTests"]
                if mode == "only-host-target":
                    for entry in entries:
                        entry["identifier"] = entry["identifier"].replace(
                            "InnoFlowTests/", "InnoFlowMacrosTests/")
                elif mode == "extra-host-target":
                    entries.append({"identifier": "InnoFlowMacrosTests/MacroTests/hostOnly()"})
                elif mode == "missing-target":
                    entries[0]["identifier"] = entries[0]["identifier"].split("/", 1)[1]
                else:
                    entries.append({"identifier": "InnoFlowTests//"})
                self.assertTrue(RUNTIME.validate_discovery(self.inventory, discovery)[0])

    def test_malformed_discovery_fails_closed(self):
        for discovery in (None, {}, {"errors": [], "values": [None]},
                          {"errors": [], "values": [{"disabledTests": []}]},
                          {"errors": [], "values": [{"enabledTests": []}]}):
            with self.subTest(discovery=discovery):
                self.assertTrue(RUNTIME.validate_discovery(self.inventory, discovery)[0])

    def test_inventory_shape_order_and_suite_membership_are_required(self):
        for field, value in (("schemaVersion", 2), ("schemaVersion", True), ("suites", []),
                             ("suites", ["OtherTests", "FixtureConsistencyTests"]),
                             ("suites", ["FixtureConsistencyTests"]),
                             ("expectedTestIdentifiers", []),
                             ("expectedTestIdentifiers", ["malformed"]),
                             ("expectedTestIdentifiers", [None]),
                             ("expectedTestIdentifiers", ["OtherTests/control()"] * 2)):
            with self.subTest(field=field, value=value):
                inventory = {**self.inventory, field: value}
                self.assertTrue(RUNTIME.validate_discovery(inventory, self.discovery)[0])
                self.assertTrue(RUNTIME.validate(inventory, self.summary, self.tests)[0])

    def test_incomplete_and_nonpassing_results_fail(self):
        for mode in ("missing", "duplicate", "extra", "failed", "skipped", "identifier"):
            with self.subTest(mode=mode):
                tests = copy.deepcopy(self.tests)
                cases = tests["tests"]
                if mode == "missing":
                    cases.pop()
                elif mode == "duplicate":
                    cases.append(cases[0])
                elif mode == "extra":
                    cases.append({**cases[0], "nodeIdentifier": "OtherTests/new()"})
                elif mode == "identifier":
                    del cases[0]["nodeIdentifier"]
                else:
                    cases[0]["result"] = mode.title()
                self.assertTrue(RUNTIME.validate(self.inventory, self.summary, tests)[0])

    def test_summary_failures_skips_warnings_and_expected_failures_are_not_waived(self):
        for field, value in (("result", "Failed"), ("totalTestCount", 1),
                             ("failedTests", 1), ("skippedTests", 1),
                             ("expectedFailures", 1), ("runtimeWarnings", ["warning"])):
            with self.subTest(field=field):
                self.assertTrue(RUNTIME.validate(
                    self.inventory, {**self.summary, field: value}, self.tests)[0])


if __name__ == "__main__":
    unittest.main()
