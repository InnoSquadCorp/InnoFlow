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
        self.summary = {"result": "Passed", "totalTestCount": 2, "passedTests": 2,
                        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                        "runtimeWarnings": []}
        self.tests = {"tests": [
            {"nodeType": "Test Case", "nodeIdentifier": item, "result": "Passed"}
            for item in self.inventory["expectedTestIdentifiers"]
        ]}

    def test_compiler_conditional_selection_keeps_exact_discovery_and_results(self):
        conditional = self.inventory["expectedTestIdentifiers"][0]
        self.inventory["conditionalContextsByIdentifier"] = {conditional: ["#if compiler(>=6.4)"]}
        for version in ("6.3", "6.4"):
            with self.subTest(version=version):
                discovery = copy.deepcopy(self.discovery)
                tests = copy.deepcopy(self.tests)
                summary = copy.deepcopy(self.summary)
                if version == "6.3":
                    discovery["values"][0]["enabledTests"].pop(0)
                    tests["tests"].pop(0)
                    summary.update(totalTestCount=1, passedTests=1)
                output = "Apple Swift version " + version + ".0 (swiftlang-fixture)"
                self.assertEqual(RUNTIME.validate_discovery(self.inventory, discovery, output)[0], [])
                self.assertEqual(RUNTIME.validate(self.inventory, summary, tests, output)[0], [])
                wrong = "Swift version " + ("6.4" if version == "6.3" else "6.3")
                self.assertTrue(RUNTIME.validate_discovery(self.inventory, discovery, wrong)[0])
                self.assertTrue(RUNTIME.validate(self.inventory, summary, tests, wrong)[0])

    def test_conditional_inventory_rejects_unknown_conditions_and_missing_compiler(self):
        conditional = self.inventory["expectedTestIdentifiers"][0]
        for contexts in (["#if compiler(>=6.4)"], ["#if canImport(FutureKit)"],
                         ["#elseif compiler(>=6.4)"], ["#else "], [], None, "#if compiler(>=6.4)"):
            with self.subTest(contexts=contexts):
                self.inventory["conditionalContextsByIdentifier"] = {conditional: contexts}
                self.assertTrue(RUNTIME.validate_discovery(self.inventory, self.discovery)[0])
                self.assertTrue(RUNTIME.validate(self.inventory, self.summary, self.tests)[0])
        self.inventory["conditionalContextsByIdentifier"] = {"OtherTests/phantom()": ["#if compiler(>=6.4)"]}
        self.assertTrue(RUNTIME.validate_inventory(self.inventory))

    def test_complete_discovery_and_results_pass(self):
        self.assertEqual(RUNTIME.validate_discovery(self.inventory, self.discovery)[0], [])
        self.assertEqual(RUNTIME.validate(self.inventory, self.summary, self.tests), ([], 2))

    def test_split_target_ownership_and_future_consistency_discovery_are_exact(self):
        self.inventory["suiteTargets"] = {"FixtureConsistencyTests": "InnoFlowCoreTests",
                                         "OtherTests": "InnoFlowTestingTests"}
        self.inventory["discoveryTargets"] = ["InnoFlowCoreTests", "InnoFlowSwiftUITests", "InnoFlowTestingTests"]
        for entry in self.discovery["values"][0]["enabledTests"]:
            _, suite, test = entry["identifier"].split("/", 2)
            entry["identifier"] = self.inventory["suiteTargets"][suite] + "/" + suite + "/" + test
        self.assertEqual(RUNTIME.validate_discovery(self.inventory, self.discovery)[0], [])
        changed = copy.deepcopy(self.discovery)
        changed["values"][0]["enabledTests"][0]["identifier"] = "InnoFlowTestingTests/FixtureConsistencyTests/parameterized(value:)"
        self.assertTrue(RUNTIME.validate_discovery(self.inventory, changed)[0])
        changed = copy.deepcopy(self.discovery)
        changed["values"][0]["enabledTests"].append({"identifier": "InnoFlowSwiftUITests/NewConsistencyTests/test()"})
        self.assertIn("unreviewed-consistency-suite=NewConsistencyTests",
                      RUNTIME.validate_discovery(self.inventory, changed)[0])
        for ownership in (None, {}, {"FixtureConsistencyTests": "InnoFlowMacrosTests"}):
            with self.subTest(ownership=ownership):
                self.assertTrue(RUNTIME.validate_inventory({**self.inventory, "suiteTargets": ownership}))

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

    def diagnostic_fixture(self):
        inventory = copy.deepcopy(self.inventory)
        inventory["expectedFailureTestIdentifiers"] = [inventory["expectedTestIdentifiers"][0]]
        summary = {**self.summary, "passedTests": 1, "expectedFailures": 1}
        tests = copy.deepcopy(self.tests)
        tests["tests"][0]["result"] = "Expected Failure"
        return inventory, summary, tests

    def test_reviewed_diagnostic_is_required_with_exact_passed_count(self):
        self.assertEqual(RUNTIME.validate(*self.diagnostic_fixture()), ([], 2))

    def test_malformed_or_unreviewed_diagnostic_inventory_fails(self):
        for diagnostics in (None, True, "OtherTests/control()", [None],
                            ["OtherTests/unknown()"], ["OtherTests/control()"] * 2,
                            list(reversed(self.inventory["expectedTestIdentifiers"]))):
            with self.subTest(diagnostics=diagnostics):
                inventory = {**self.inventory, "expectedFailureTestIdentifiers": diagnostics}
                self.assertTrue(RUNTIME.validate(inventory, self.summary, self.tests)[0])

    def test_missing_extra_swapped_or_failed_diagnostic_is_rejected(self):
        for mode in ("missing", "extra", "swapped", "failed", "skipped", "renamed",
                     "duplicate", "absent", "no-longer-fails", "ordinary-failure"):
            with self.subTest(mode=mode):
                inventory, summary, tests = self.diagnostic_fixture()
                cases = tests["tests"]
                if mode == "missing":
                    cases[0]["result"] = "Passed"
                elif mode == "extra":
                    cases[1]["result"] = "Expected Failure"
                elif mode == "swapped":
                    cases[0]["result"], cases[1]["result"] = "Passed", "Expected Failure"
                elif mode == "renamed":
                    cases[0]["nodeIdentifier"] = "FixtureConsistencyTests/other()"
                elif mode == "duplicate":
                    cases.append(cases[0])
                elif mode == "absent":
                    cases.pop(0)
                elif mode == "no-longer-fails":
                    cases[0]["result"] = "Passed"
                    summary.update(passedTests=2, expectedFailures=0)
                elif mode == "ordinary-failure":
                    cases[1]["result"] = "Failed"
                    summary.update(passedTests=0, failedTests=1)
                else:
                    cases[0]["result"] = mode.title()
                self.assertTrue(RUNTIME.validate(inventory, summary, tests)[0])

    def test_diagnostic_summary_counters_are_required_exact_integers(self):
        for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"):
            for value in (None, False, True, "0", "1", 0.0, 1.0, -1, 99):
                with self.subTest(key=key, value=value):
                    inventory, summary, tests = self.diagnostic_fixture()
                    summary[key] = value
                    self.assertTrue(RUNTIME.validate(inventory, summary, tests)[0])
            inventory, summary, tests = self.diagnostic_fixture()
            del summary[key]
            self.assertTrue(RUNTIME.validate(inventory, summary, tests)[0])

    def test_diagnostic_warnings_and_failed_summary_still_fail(self):
        for field, value in (("runtimeWarnings", ["warning"]), ("runtimeWarnings", {}),
                             ("runtimeWarnings", None), ("result", "Failed"),
                             ("passedTests", 2), ("expectedFailures", 2)):
            with self.subTest(field=field, value=value):
                inventory, summary, tests = self.diagnostic_fixture()
                summary[field] = value
                self.assertTrue(RUNTIME.validate(inventory, summary, tests)[0])

    def test_malformed_result_payload_is_rejected(self):
        for summary, tests in ((None, self.tests), (self.summary, [])):
            self.assertTrue(RUNTIME.validate(self.inventory, summary, tests)[0])


if __name__ == "__main__":
    unittest.main()
