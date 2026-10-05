"""Exact OS27 capability outcomes; synthetic xcresult shape, not Apple execution."""
import copy
import importlib.util
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swift_test_conditions import (DID_SET_TESTS, DID_SET_CAPABILITY, DID_SET_AVAILABILITY,
    source_capabilities, runtime_capabilities, runtime_selection, simulator_runtime)
SPEC = importlib.util.spec_from_file_location("runtime", Path(__file__).resolve().parents[1] / "validate-focused-runtime-result.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class RuntimeAvailabilityTests(unittest.TestCase):
    def setUp(self):
        self.identifiers = sorted(["CommonTests/control()", *DID_SET_TESTS])
        self.inventory = {"schemaVersion": 1,
            "suites": ["CommonTests", "SnapshotBoundaryConsistencyTests"],
            "expectedTestIdentifiers": self.identifiers,
            "conditionalContextsByIdentifier": dict.fromkeys(DID_SET_TESTS, ["#if compiler(>=6.4)"]),
            "requiredCapabilitiesByIdentifier": dict.fromkeys(DID_SET_TESTS, DID_SET_CAPABILITY)}
        self.compiler = "Apple Swift version 6.4 (fixture)"

    def fixture(self, version="27.0", platform="iOS Simulator"):
        runtime = {"platform": platform, "os": version, "deviceId": "fixture-device"}
        unavailable = [] if version == "27.0" else list(DID_SET_TESTS)
        summary = {"result": "Passed", "totalTestCount": 4, "passedTests": 4-len(unavailable),
            "failedTests": 0, "skippedTests": len(unavailable), "expectedFailures": 0,
            "devicesAndConfigurations": [{"device": {"platform": platform, "osVersion": version,
                                                        "deviceId": runtime["deviceId"]}}]}
        tests = {"tests": [{"nodeType": "Test Case", "nodeIdentifier": identifier,
            "result": "Skipped" if identifier in unavailable else "Passed"} for identifier in self.identifiers]}
        discovery = {"errors": [], "values": [{"enabledTests": [{"identifier": "InnoFlowTests/"+identifier}
            for identifier in self.identifiers], "disabledTests": []}]}
        return runtime, summary, tests, discovery

    def test_exact_outcomes_on_every_reviewed_legacy_and_current_runtime(self):
        for platform, legacy in (("iOS Simulator", "18.5"), ("tvOS Simulator", "18.5"),
                                 ("watchOS Simulator", "11.5"), ("visionOS Simulator", "2.5")):
            for version in (legacy, "27.0"):
                with self.subTest(platform=platform, version=version):
                    runtime, summary, tests, discovery = self.fixture(version, platform)
                    self.assertEqual(RUNTIME.validate(self.inventory, summary, tests, self.compiler, runtime), ([], 4))
                    self.assertTrue(RUNTIME.validate(self.inventory, summary, tests, self.compiler)[0])
                    self.assertEqual(RUNTIME.validate_discovery(self.inventory, discovery, self.compiler, runtime)[0], [])
                    selected = runtime_selection(self.inventory, self.compiler, runtime)
                    self.assertEqual(len(selected["expectedTestIdentifiers"]), 4)
                    self.assertEqual(len(selected["expectedUnavailableTestIdentifiers"]), 0 if version == "27.0" else 3)

    def test_legacy_empty_pass_and_modern_skip_are_rejected(self):
        for version in ("18.5", "27.0"):
            runtime, summary, tests, _ = self.fixture(version)
            for case in tests["tests"]:
                if case["nodeIdentifier"] in DID_SET_TESTS:
                    case["result"] = "Passed" if version == "18.5" else "Skipped"
            summary.update(passedTests=4 if version == "18.5" else 1, skippedTests=0 if version == "18.5" else 3)
            self.assertTrue(RUNTIME.validate(self.inventory, summary, tests, self.compiler, runtime)[0])

    def test_identity_missing_unknown_conflicting_or_substituted_is_rejected(self):
        for mode in ("missing", "unknown-os", "unknown-platform", "wrong-device", "extra-device"):
            runtime, summary, tests, _ = self.fixture("18.5")
            device = summary["devicesAndConfigurations"][0]["device"]
            if mode == "missing":
                del summary["devicesAndConfigurations"]
            elif mode == "unknown-os": device["osVersion"] = "28.0"
            elif mode == "unknown-platform": device["platform"] = "Other Simulator"
            elif mode == "wrong-device": device["deviceId"] = "other-device"
            else: tests["devices"] = [{**device, "osVersion": "27.0"}]
            with self.subTest(mode=mode):
                self.assertTrue(RUNTIME.validate(self.inventory, summary, tests, self.compiler, runtime)[0])

    def test_discovery_retains_exact_unavailable_ids_and_rejects_missing_or_other_disabled(self):
        runtime, _, _, discovery = self.fixture("18.5")
        entries = discovery["values"][0]
        entries["disabledTests"] = entries["enabledTests"][1:]
        entries["enabledTests"] = entries["enabledTests"][:1]
        self.assertEqual(RUNTIME.validate_discovery(self.inventory, discovery, self.compiler, runtime)[0], [])
        self.assertTrue(RUNTIME.validate_discovery(self.inventory, discovery, self.compiler, {**runtime, "os": "27.0"})[0])
        self.assertTrue(RUNTIME.validate_discovery(self.inventory, discovery, self.compiler)[0])
        for mode in ("missing", "duplicate", "ordinary-disabled"):
            changed = copy.deepcopy(discovery)
            values = changed["values"][0]
            if mode == "missing": values["disabledTests"].pop()
            elif mode == "duplicate": values["disabledTests"].append(values["disabledTests"][0])
            else: values["disabledTests"] += values["enabledTests"]; values["enabledTests"] = []
            with self.subTest(mode=mode):
                self.assertTrue(RUNTIME.validate_discovery(self.inventory, changed, self.compiler, runtime)[0])

    def test_ordinary_skips_and_missing_unavailable_identity_are_rejected(self):
        runtime, summary, tests, _ = self.fixture("18.5")
        for mode in ("ordinary-skip", "missing", "duplicate", "unavailable-failed", "wrong-counter"):
            changed = copy.deepcopy(tests)
            counts = dict(summary)
            if mode == "ordinary-skip": changed["tests"][0]["result"] = "Skipped"
            elif mode == "missing": changed["tests"].pop()
            elif mode == "duplicate": changed["tests"].append(changed["tests"][-1])
            elif mode == "unavailable-failed": changed["tests"][-1]["result"] = "Failed"
            else: counts["skippedTests"] = 2
            with self.subTest(mode=mode):
                self.assertTrue(RUNTIME.validate(self.inventory, counts, changed, self.compiler, runtime)[0])

    def test_capability_is_source_pinned_and_cannot_be_partial_or_widened(self):
        source = {"tests": [{"target": "InnoFlowTests", "identifier": identifier,
            "conditionalContexts": ["#if compiler(>=6.4)"], "availabilityAttributes": [DID_SET_AVAILABILITY]}
            for identifier in DID_SET_TESTS]}
        self.assertEqual(source_capabilities(source), self.inventory["requiredCapabilitiesByIdentifier"])
        for mode in ("missing-attribute", "wrong-attribute", "missing-declaration", "wrong-condition"):
            changed = copy.deepcopy(source)
            if mode == "missing-attribute": del changed["tests"][0]["availabilityAttributes"]
            elif mode == "wrong-attribute": changed["tests"][0]["availabilityAttributes"] = ["@available(iOS 26.0, *)"]
            elif mode == "missing-declaration": changed["tests"].pop()
            else: changed["tests"][0]["conditionalContexts"] = []
            with self.subTest(mode=mode), self.assertRaises(ValueError): source_capabilities(changed)
        omitted = copy.deepcopy(source)
        omitted["tests"] = [{"target": "InnoFlowTests", "identifier": "SnapshotBoundaryConsistencyTests/common()", "conditionalContexts": []}]
        with self.assertRaises(ValueError): source_capabilities(omitted)
        absent_map = copy.deepcopy(self.inventory)
        del absent_map["requiredCapabilitiesByIdentifier"]
        with self.assertRaises(ValueError): runtime_capabilities(absent_map)
        for identifier in (DID_SET_TESTS[0], "CommonTests/control()"):
            changed = copy.deepcopy(self.inventory)
            changed["requiredCapabilitiesByIdentifier"] = {identifier: DID_SET_CAPABILITY}
            with self.assertRaises(ValueError): runtime_capabilities(changed)

    def test_compiler63_omission_is_distinct_from_runtime_unavailability(self):
        selected = runtime_selection(self.inventory, "Swift version 6.3")
        self.assertEqual(selected["expectedTestIdentifiers"], ["CommonTests/control()"])
        self.assertEqual(selected["expectedUnavailableTestIdentifiers"], [])

    def test_simulator_identity_is_resolved_from_device_and_runtime_catalog(self):
        runtime_id = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
        devices = {"devices": {runtime_id: [{"udid": "fixture-device", "isAvailable": True}]}}
        runtimes = {"runtimes": [{"identifier": runtime_id, "version": "18.5", "isAvailable": True}]}
        self.assertEqual(simulator_runtime("platform=iOS Simulator,id=fixture-device", devices, runtimes),
                         {"platform": "iOS Simulator", "os": "18.5", "deviceId": "fixture-device"})
        for destination in ("platform=iOS Simulator,OS=18.5,name=iPhone", "platform=tvOS Simulator,id=fixture-device", "platform=iOS Simulator,id=absent"):
            with self.assertRaises(ValueError): simulator_runtime(destination, devices, runtimes)
        runtimes["runtimes"][0]["isAvailable"] = False
        with self.assertRaises(ValueError): simulator_runtime("platform=iOS Simulator,id=fixture-device", devices, runtimes)


if __name__ == "__main__": unittest.main()
