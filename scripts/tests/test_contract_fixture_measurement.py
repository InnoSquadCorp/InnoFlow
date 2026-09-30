"""Linux-runnable negative controls; fake Swift output is never Mac evidence."""

from copy import deepcopy
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("measure_contract_fixtures", ROOT / "scripts/measure-contract-fixtures.py")
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)


def sample_events(revision):
    events = []

    def append(arguments, *, status=0, scenario=None, executable="/usr/bin/xcrun", manifest="", cold=False):
        events.append({"schemaVersion": 1, "id": str(len(events)), "parentPID": 1234,
                       "executable": executable, "arguments": arguments,
                       "scenarioEnvironment": scenario or {}, "elapsedSeconds": 1.25,
                       "startedUptime": len(events) * 2, "status": status,
                       "buildPathExisted": not cold, "consumerManifest": manifest})

    modes = ["-Onone"] * (7 if revision == "baseline" else 2) + ["-O"] * (9 if revision == "baseline" else 3)
    for mode in modes:
        append(["swiftc", mode, "-parse-as-library", "-package-name", "InnoFlow", "Probe.swift", "-o", "Probe"])
    for key, variants in BENCH.SCENARIOS.items():
        for value, succeeds in variants.items():
            append([], status=0 if succeeds else 4, scenario={key: value}, executable="/tmp/Probe")
    for index, flags in enumerate(BENCH.VARIANTS):
        build_path = "/tmp/build" + (f"/variant-{index}" if revision == "baseline" and index else "")
        arguments = ["swift", "build", "--package-path", "/tmp/Consumer", "--build-path", build_path,
                     "--product", "PublicMacroClient", "--disable-experimental-prebuilts", "-Xswiftc", "-warnings-as-errors"]
        manifest = ""
        if revision == "baseline":
            for flag in flags:
                arguments += ["-Xswiftc", "-D" + flag]
        else:
            settings = ", ".join(f'.define("{flag}")' for flag in flags)
            manifest = f"swiftSettings: [{settings}], swiftSettings: [{settings}]"
        append(arguments, manifest=manifest, cold=revision == "baseline" or index == 0)
    base_arguments = ["swift", "build", "--package-path", "/tmp/Consumer", "--build-path", "/tmp/build",
                      "--product", "PublicMacroClient", "--disable-experimental-prebuilts", "-Xswiftc", "-warnings-as-errors"]
    negative_manifest = "swiftSettings: [], swiftSettings: []" if revision == "candidate" else ""
    append(base_arguments, status=1, manifest=negative_manifest)
    extension = base_arguments.copy()
    extension[extension.index("--build-path") + 1] += "/application-extension"
    append(extension + ["-Xswiftc", "-application-extension"], status=1, cold=True, manifest=negative_manifest)
    append([], executable="/tmp/build/debug/PublicMacroClient")
    return events


def passing_output(titles):
    return "\n".join([f'✔ Test "{title}" passed after 1.234 seconds.' for title in titles.values()] +
                     ['✔ Test run with 17 tests passed after 123.456 seconds.'])


class ContractMeasurementTests(unittest.TestCase):
    def setUp(self):
        self.titles = BENCH.inventory(ROOT)

    def test_exact_inventory_has_all_seventeen_functions(self):
        self.assertEqual(len(self.titles), 17)
        self.assertEqual(sorted(self.titles), BENCH.EXPECTED_IDS)

    def test_identical_observer_insertion_preserves_original(self):
        source = (ROOT / BENCH.SUPPORT_PATH).read_text()
        patched = BENCH.instrument(source)
        self.assertEqual(patched.replace(BENCH.OBSERVED_WAIT, BENCH.ORIGINAL_WAIT), source)
        self.assertIn("try process.run()\n    process.waitUntilExit()", patched)
        with self.assertRaisesRegex(ValueError, "anchor|present"):
            BENCH.instrument(patched)
        with self.assertRaisesRegex(ValueError, "exactly once"):
            BENCH.instrument(source + BENCH.ORIGINAL_WAIT)

    def test_complete_discovery_accepts_module_prefix(self):
        output = "\n".join("InnoFlowTests." + item for item in BENCH.EXPECTED_IDS)
        output += "\nInnoFlowTests.CompileContractTests/unrelated()"
        self.assertEqual(sorted(BENCH.validate_discovery(output)), BENCH.EXPECTED_IDS)

    def test_discovery_rejects_missing_duplicate_or_added_suite_case(self):
        good = "\n".join(BENCH.EXPECTED_IDS)
        for bad in ("\n".join(BENCH.EXPECTED_IDS[:-1]), good + "\n" + BENCH.EXPECTED_IDS[0],
                    good + "\nStaleScopeCrashContractTests/newUnmeasuredContract()"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                BENCH.validate_discovery(bad)

    def test_output_requires_all_passing_titles_and_final_count(self):
        good = passing_output(self.titles)
        self.assertEqual(len(BENCH.validate_test_output(good, self.titles)), 17)
        for bad in ("\n".join(good.splitlines()[1:]), good.replace("17 tests passed", "16 tests passed"),
                    good + '\n✔ Test "extra" passed after 1.0 seconds.', good.replace("passed after", "skipped after", 1)):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                BENCH.validate_test_output(bad, self.titles)

    def test_real_swift_63_summary_with_suite_count(self):
        good = passing_output(self.titles).replace("17 tests passed", "17 tests in 5 suites passed")
        self.assertEqual(len(BENCH.validate_test_output(good, self.titles)), 17)
        eight = dict(list(self.titles.items())[:7])
        eight["cacheFailedBuildTitle"] = "A failed build is removed and the same key can retry successfully"
        output = "\n".join(f'✔ Test "{title}" passed after 0.004 seconds.' for title in eight.values())
        output += "\n✔ Test run with 8 tests in 1 suite passed after 0.040 seconds."
        self.assertEqual(len(BENCH.validate_test_output(output, eight)), 8)

    def test_baseline_and_candidate_expected_counts(self):
        for revision, count, roots in (("baseline", 16, 10), ("candidate", 5, 2)):
            with self.subTest(revision=revision):
                result = BENCH.validate_events(sample_events(revision), revision)
                self.assertEqual(result["directSwiftcInvocations"], count)
                self.assertEqual(len(result["macroScratchRoots"]), roots)
                self.assertEqual(result["nestedSwiftBuildInvocations"], 11)
                self.assertEqual(result["scenarioExecutions"], 16)
                self.assertEqual(result["directSwiftcSeconds"], count * 1.25)

    def test_missing_scenario_cannot_be_a_cache_speedup(self):
        events = sample_events("candidate")
        events.pop(next(index for index, event in enumerate(events) if event["scenarioEnvironment"]))
        with self.assertRaisesRegex(ValueError, "16 subprocess"):
            BENCH.validate_events(events, "candidate")

    def test_wrong_scenario_outcome_fails(self):
        events = sample_events("candidate")
        next(event for event in events if event["scenarioEnvironment"])["status"] = 0
        with self.assertRaisesRegex(ValueError, "scenario outcome"):
            BENCH.validate_events(events, "candidate")

    def test_missing_positive_variant_fails(self):
        events = sample_events("candidate")
        next(event for event in events if "FEATURE_A" in event["consumerManifest"])["consumerManifest"] = "swiftSettings: [], swiftSettings: []"
        with self.assertRaisesRegex(ValueError, "nine positive"):
            BENCH.validate_events(events, "candidate")

    def test_candidate_cannot_omit_define_from_one_target(self):
        events = sample_events("candidate")
        event = next(event for event in events if "FEATURE_A" in event["consumerManifest"])
        event["consumerManifest"] = 'swiftSettings: [.define("FEATURE_A")], swiftSettings: []'
        with self.assertRaisesRegex(ValueError, "identical"):
            BENCH.validate_events(events, "candidate")

    def test_candidate_cannot_use_different_flags_between_targets(self):
        events = sample_events("candidate")
        event = next(event for event in events if "FEATURE_A" in event["consumerManifest"])
        event["consumerManifest"] = 'swiftSettings: [.define("FEATURE_A")], swiftSettings: [.define("FEATURE_B")]'
        with self.assertRaisesRegex(ValueError, "identical"):
            BENCH.validate_events(events, "candidate")

    def test_candidate_requires_both_fixture_settings_blocks(self):
        events = sample_events("candidate")
        event = next(event for event in events if "FEATURE_A" in event["consumerManifest"])
        event["consumerManifest"] = 'swiftSettings: [.define("FEATURE_A")]'
        with self.assertRaisesRegex(ValueError, "exactly two"):
            BENCH.validate_events(events, "candidate")

    def test_extension_global_mode_cannot_be_removed(self):
        events = sample_events("candidate")
        next(event for event in events if "-application-extension" in event["arguments"])["arguments"].remove("-application-extension")
        with self.assertRaisesRegex(ValueError, "application-extension"):
            BENCH.validate_events(events, "candidate")

    def test_source_fallback_cannot_be_removed(self):
        events = sample_events("candidate")
        next(event for event in events if "--disable-experimental-prebuilts" in event["arguments"])["arguments"].remove("--disable-experimental-prebuilts")
        with self.assertRaisesRegex(ValueError, "source fallback"):
            BENCH.validate_events(events, "candidate")

    def test_reused_cold_fixture_is_rejected(self):
        events = sample_events("candidate")
        next(event for event in events if event["arguments"][:2] == ["swift", "build"])["buildPathExisted"] = True
        with self.assertRaisesRegex(ValueError, "start cold"):
            BENCH.validate_events(events, "candidate")

    def test_cache_cannot_span_test_processes(self):
        events = sample_events("candidate")
        events[0]["parentPID"] = 999
        with self.assertRaisesRegex(ValueError, "one test process"):
            BENCH.validate_events(events, "candidate")

    def test_extra_compile_cannot_hide(self):
        events = sample_events("candidate")
        extra = deepcopy(events[0])
        extra["id"] = "extra"
        events.append(extra)
        with self.assertRaisesRegex(ValueError, "5 direct"):
            BENCH.validate_events(events, "candidate")

    def test_debug_and_release_compilation_modes_preserved(self):
        events = sample_events("candidate")
        events[0]["arguments"][1] = "-O"
        with self.assertRaisesRegex(ValueError, "Onone"):
            BENCH.validate_events(events, "candidate")

    def test_workflow_event_is_exact_branch_same_repo_and_sha(self):
        event = {"number": 99, "pull_request": {
            "base": {"ref": BENCH.BASE_BRANCH, "sha": BENCH.BASELINE_SHA, "repo": {"full_name": "owner/Flow"}},
            "head": {"ref": BENCH.HEAD_BRANCH, "sha": "a" * 40, "repo": {"full_name": "owner/Flow"}},
        }}
        self.assertEqual(BENCH.verify_event(event, "a" * 40)["number"], 99)
        for path, value in ((["head", "ref"], "main"), (["base", "ref"], "main"),
                            (["head", "sha"], "b" * 40), (["head", "repo", "full_name"], "fork/Flow")):
            bad = deepcopy(event)
            target = bad["pull_request"]
            for part in path[:-1]:
                target = target[part]
            target[path[-1]] = value
            with self.subTest(path=path), self.assertRaises(ValueError):
                BENCH.verify_event(bad, "a" * 40)

    def test_workflow_is_bounded_read_only_and_pr_triggered(self):
        source = (ROOT / ".github/workflows/contract-fixture-measurement.yml").read_text()
        self.assertIn("pull_request:", source)
        self.assertNotIn("workflow_dispatch:", source)
        self.assertNotIn("pull_request_target", source)
        self.assertIn("timeout-minutes: 60", source)
        self.assertIn("runs-on: macos-26", source)
        self.assertIn("Xcode_26.6.app", source)
        self.assertEqual(source.count("persist-credentials: false"), 2)
        self.assertNotRegex(source, r"\b(?:contents|actions|id-token|pull-requests): write")
        self.assertIn("if: always()", source)

    def test_failed_command_preserves_stdout_stderr_and_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = BENCH.run_command([sys.executable, "-c", "import sys; print('out'); print('err',file=sys.stderr);sys.exit(7)"],
                                       root, os.environ, root / "logs", time.monotonic() + 5)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["returnCode"], 7)
            self.assertIn("out", (root / "logs/stdout.log").read_text())
            self.assertIn("err", (root / "logs/stderr.log").read_text())
            self.assertEqual(json.loads((root / "logs/command.json").read_text())["status"], "failed")

    def test_timeout_stops_process_group_and_preserves_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = BENCH.run_command([sys.executable, "-c", "import time;print('started',flush=True);time.sleep(30)"],
                                       root, os.environ, root / "logs", time.monotonic() + 0.2)
            self.assertEqual(result["status"], "timed-out")
            self.assertLess(result["elapsedSeconds"], 6)
            self.assertIn("started", (root / "logs/stdout.log").read_text())

    def test_expired_budget_does_not_launch_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = BENCH.run_command(["not-a-real-command"], root, os.environ, root / "logs", time.monotonic() - 1)
            self.assertEqual(result["status"], "failed")
            self.assertIn("budget exhausted", result["error"])

    def fake_swift(self, root, revision, *, failed=False, missing_diagnostic=False):
        fake = root / "fake-swift.py"
        payload = {"events": sample_events(revision), "titles": self.titles, "ids": BENCH.EXPECTED_IDS,
                   "output": passing_output(self.titles), "failed": failed, "missingDiagnostic": missing_diagnostic}
        (root / "payload.json").write_text(json.dumps(payload))
        fake.write_text('''import json, os, sys
from pathlib import Path
p = json.loads(Path(__file__).with_name("payload.json").read_text())
if sys.argv[1] == "build":
    print("Build complete! (0.123s)")
elif "list" in sys.argv:
    print("\\n".join("InnoFlowTests." + item for item in p["ids"]))
else:
    destination = Path(os.environ["INNOFLOW_BENCHMARK_EVENTS"])
    for event in p["events"]:
        (destination / (event["id"] + ".json")).write_text(json.dumps(event))
        (destination / (event["id"] + ".stdout.log")).write_text("fake compiler output")
        diagnostic = "error: unavailable" if event["status"] != 0 and not p["missingDiagnostic"] else ""
        (destination / (event["id"] + ".stderr.log")).write_text(diagnostic)
    print(p["output"])
    sys.exit(1 if p["failed"] else 0)
''')
        return [sys.executable, str(fake)]

    def test_fake_end_to_end_phase_has_no_nested_time_double_count(self):
        for revision in ("baseline", "candidate"):
            with self.subTest(revision=revision), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                prefix = self.fake_swift(root, revision)
                result = BENCH.measure_phase(root, revision, "clean", self.titles, root / "logs", root / "tmp",
                                             time.monotonic() + 10, prefix)
                self.assertEqual(result["status"], "passed", result)
                self.assertAlmostEqual(result["buildPlusTestSeconds"],
                                       result["rootBuild"]["elapsedSeconds"] + result["testExecution"]["elapsedSeconds"])
                self.assertGreater(result["subprocesses"]["nestedSwiftBuildSeconds"], result["buildPlusTestSeconds"])
                self.assertEqual(result["observedEventCount"], 44 if revision == "baseline" else 33)

    def test_fake_failed_tests_keep_raw_events(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = self.fake_swift(root, "candidate", failed=True)
            result = BENCH.measure_phase(root, "candidate", "clean", self.titles, root / "logs", root / "tmp",
                                         time.monotonic() + 10, prefix)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["observedEventCount"], 33)
            self.assertTrue((root / "logs/candidate-clean/events.json").exists())
            self.assertNotIn("buildPlusTestSeconds", result)

    def test_fake_negative_control_without_diagnostic_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = self.fake_swift(root, "candidate", missing_diagnostic=True)
            result = BENCH.measure_phase(root, "candidate", "clean", self.titles, root / "logs", root / "tmp",
                                         time.monotonic() + 10, prefix)
            self.assertEqual(result["status"], "failed")
            self.assertIn("unavailable diagnostic", result["errors"][0])

    def test_non_macos_cli_fails_closed_but_writes_summary(self):
        if sys.platform == "darwin":
            self.skipTest("Linux-only environment rejection control")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = subprocess.run([sys.executable, "-B", str(ROOT / "scripts/measure-contract-fixtures.py"),
                                     "--baseline", str(root / "base"), "--candidate", str(root / "candidate"),
                                     "--candidate-sha", "a" * 40, "--output", str(root / "out"),
                                     "--temporary", str(root / "tmp")], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            summary = json.loads((root / "out/summary.json").read_text())
            self.assertEqual(summary["status"], "failed")
            self.assertIn("requires macOS", summary["errors"][0])


if __name__ == "__main__":
    unittest.main()
