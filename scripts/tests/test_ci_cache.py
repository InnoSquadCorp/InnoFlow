"""Offline positive/negative controls for dependency-only exact cache profiles."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci-cache.py"
spec = importlib.util.spec_from_file_location("ci_cache", SCRIPT)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


def inputs():
    return {path: (ROOT / path).read_text() for path in sorted(cache.REQUIRED_INPUTS)}


def toolchain():
    return {
        "swift": "Apple Swift version 6.3 (swiftlang-6.3.0.4.1 clang-1700.6.5.2)\nTarget: arm64-apple-macosx26.0",
        "swift-path": "/Applications/Xcode_26.6.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        "xcode": "Xcode 26.6\nBuild version 17G42",
        "developer-dir": "/Applications/Xcode_26.6.app/Contents/Developer",
        "os-version": "26.6", "os-build": "25G42", "architecture": "arm64",
        "sdks": {name + "26.6": {"version": "26.6", "build": "25G42"} for name in (
            "macosx", "iphoneos", "iphonesimulator", "appletvos", "appletvsimulator",
            "watchos", "watchsimulator", "xros", "xrsimulator")},
    }


def fingerprint(**overrides):
    return cache.fingerprint(**{"inputs": inputs(), "toolchain": toolchain(), "profile": "tests",
                                "contract": "offline cache implementation contract", **overrides})


class FingerprintTests(unittest.TestCase):
    def test_deterministic_nonempty_full_digest_and_allowlisted_paths(self):
        first = fingerprint()
        self.assertEqual(first, fingerprint(inputs=dict(reversed(list(inputs().items())))))
        self.assertRegex(first["dependency-key"], r"^innoflow-swiftpm-deps-v1-tests-default-[0-9a-f]{64}$")
        self.assertEqual(first["dependency-paths"], [
            "~/Library/Caches/org.swift.swiftpm/repositories", "~/Library/Caches/org.swift.swiftpm/prebuilts"])
        self.assertNotIn(".build", "\n".join(first["dependency-paths"]))
        self.assertNotIn("consumer-key", first)
        self.assertEqual(first, json.loads(json.dumps(first)))

    def test_every_manifest_lock_compiler_sdk_arch_os_and_contract_affects_key(self):
        original = fingerprint()["dependency-key"]
        for path in inputs():
            updated = inputs()
            if path.endswith("Package.resolved"):
                lock = json.loads(updated[path])
                lock["pins"][0]["state"]["revision"] = "1" * 40
                updated[path] = json.dumps(lock)
            else:
                updated[path] += "\n// changed manifest\n"
            with self.subTest(path=path):
                self.assertNotEqual(original, fingerprint(inputs=updated)["dependency-key"])
        for key, value in (
            ("swift", toolchain()["swift"].replace("6.3.0.4.1", "6.3.0.4.2")),
            ("swift-path", "/fixture/other/swift"), ("xcode", "Xcode 26.6\nBuild version 17G43"),
            ("developer-dir", "/fixture/other/Developer"), ("os-version", "26.6.1"),
            ("os-build", "25G43"), ("architecture", "x86_64"),
        ):
            with self.subTest(toolchain=key):
                updated = {**toolchain(), key: value}
                self.assertNotEqual(original, fingerprint(toolchain=updated)["dependency-key"])
        for sdk in toolchain()["sdks"]:
            updated = toolchain()
            updated["sdks"][sdk]["build"] = "25G43"
            self.assertNotEqual(original, fingerprint(toolchain=updated)["dependency-key"])
        self.assertNotEqual(original, fingerprint(contract="updated implementation")["dependency-key"])
        updated = inputs()
        updated["Fixtures/New/Package.swift"] = "// swift-tools-version: 6.3\n// local dependency"
        self.assertNotEqual(original, fingerprint(inputs=updated)["dependency-key"])
        updated["Fixtures/New/Package.resolved"] = updated["Package.resolved"]
        self.assertNotEqual(original, fingerprint(inputs=updated)["dependency-key"])

    def test_profiles_are_explicit_and_never_share_keys(self):
        keys = set()
        for profile, contract in cache.PROFILES.items():
            for variant in contract.get("platforms", contract.get("versions", ("default",))):
                resolved, compiler = inputs(), toolchain()
                if profile == "swift-syntax-compatibility":
                    lock = json.loads(resolved["Package.resolved"])
                    lock["pins"][0]["state"]["version"] = variant
                    resolved["Package.resolved"] = json.dumps(lock)
                    if variant == "604.0.0":
                        compiler["swift"] = compiler["swift"].replace("6.3", "6.4")
                result = fingerprint(profile=profile, variant=variant, inputs=resolved, toolchain=compiler)
                self.assertNotIn(result["dependency-key"], keys)
                keys.add(result["dependency-key"])
                self.assertEqual(result, json.loads(json.dumps(result)), profile)
        self.assertTrue(cache.PROFILES["tests"]["source-fallback"])
        self.assertEqual(cache.PROFILES["coverage"]["instrumentation"], "code-coverage")
        for name in ("thread", "address"):
            self.assertEqual(cache.PROFILES[name + "-sanitizer"]["sanitizer"], name)

    def test_unknown_or_wrong_profile_variant_is_rejected(self):
        for profile, variant in [("unknown", "default"), ("tests", "iOS"), ("package-builds", "default"),
                                 ("sample-package-builds", "macOS"), ("swift-syntax-compatibility", "605.0.0")]:
            with self.subTest(profile=profile, variant=variant), self.assertRaises(ValueError):
                fingerprint(profile=profile, variant=variant)
        with self.assertRaisesRegex(ValueError, "after resolving"):
            fingerprint(profile="swift-syntax-compatibility", variant="603.0.0")
        with self.assertRaisesRegex(ValueError, "compiler mismatch"):
            fingerprint(profile="swift-syntax-compatibility", variant="604.0.0")

    def test_missing_empty_incomplete_toolchain_and_sdk_fail_closed(self):
        for key in toolchain():
            for replacement in (None, "", " "):
                with self.subTest(key=key, replacement=replacement), self.assertRaises(ValueError):
                    fingerprint(toolchain={**toolchain(), key: replacement})
            incomplete = toolchain()
            del incomplete[key]
            with self.assertRaises(ValueError):
                fingerprint(toolchain=incomplete)
        for key, value in [("swift", "Swift version 6.3"), ("swift", "Apple Swift version 6.5 (build)"),
                           ("swift", "Apple Swift version 6.3"), ("xcode", "Xcode 26.6"),
                           ("architecture", "unknown"), ("swift-path", "swift"),
                           ("os-version", "unknown"), ("os-build", "missing build")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fingerprint(toolchain={**toolchain(), key: value})
        for bad in [{}, {"macosx26.6": {"version": "26.6"}},
                    {"macosx26.6": {"version": "26.6", "build": ""}},
                    {"iphoneos26.6": {"version": "26.6", "build": "25G42"}}]:
            with self.assertRaises(ValueError):
                fingerprint(toolchain={**toolchain(), "sdks": bad})
        incomplete = toolchain()
        del incomplete["sdks"]["watchsimulator26.6"]
        with self.assertRaisesRegex(ValueError, "required profile SDK"):
            fingerprint(profile="focused-runtime-tests", variant="watchOS", toolchain=incomplete)

    def test_each_required_input_is_required_and_resolved_pins_are_exact(self):
        for path in inputs():
            missing = inputs()
            del missing[path]
            with self.subTest(path=path), self.assertRaises(ValueError):
                fingerprint(inputs=missing)
            for value in (None, "", " "):
                with self.assertRaises(ValueError):
                    fingerprint(inputs={**inputs(), path: value})
        self.assertIn('"603.0.0"..<"605.0.0"', inputs()["Package.swift"])
        mutations = [lambda lock: lock.update(version=1), lambda lock: lock.update(version=True),
                     lambda lock: lock.update(pins=[]), lambda lock: lock.update(pins={}),
                     lambda lock: lock["pins"].append(copy.deepcopy(lock["pins"][0])),
                     lambda lock: lock["pins"][0]["state"].update(revision="main"),
                     lambda lock: lock["pins"][0]["state"].update(version=None),
                     lambda lock: lock["pins"][0]["state"].update(branch="main"),
                     lambda lock: lock["pins"][0].update(kind="localSourceControl")]
        for mutation in mutations:
            lock = json.loads(inputs()["Package.resolved"])
            mutation(lock)
            with self.assertRaises(ValueError):
                fingerprint(inputs={**inputs(), "Package.resolved": json.dumps(lock)})
        for malformed in ("{", "null", "[]", '{"version": 3, "version": 2, "pins": []}'):
            with self.assertRaises(ValueError):
                fingerprint(inputs={**inputs(), "Package.resolved": malformed})
        for path in ("../Package.swift", "/Package.swift", "nested//Package.swift", "nested/./Package.swift"):
            with self.assertRaises(ValueError):
                fingerprint(inputs={**inputs(), path: inputs()["Package.swift"]})


class InputCollectionTests(unittest.TestCase):
    def test_tracked_manifest_lock_and_project_inventory_is_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            all_inputs = {**inputs(), "Fixtures/Consumer/Package.swift": inputs()["Package.swift"],
                          "Fixtures/Consumer/Package.resolved": inputs()["Package.resolved"],
                          "Package@swift-6.4.swift": inputs()["Package.swift"],
                          "Sample.xcodeproj/project.pbxproj": "fixture project"}
            for path, text in all_inputs.items():
                file = root / path
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text(text)
            tracked = "\0".join([*all_inputs, "Sources/Package.swift.fixture", "Sources/Feature.swift"]) + "\0"
            with mock.patch.object(cache, "command", side_effect=[tracked, ""]):
                self.assertEqual(cache.repository_inputs(root), all_inputs)
            with mock.patch.object(cache, "command", side_effect=[tracked, "New/Package.swift\0"]), self.assertRaises(ValueError):
                cache.repository_inputs(root)
            with mock.patch.object(cache, "command", return_value=tracked.replace("Package.resolved\0", "", 1)), self.assertRaises(ValueError):
                cache.repository_inputs(root)
            target = root / "Package.resolved"
            target.unlink()
            target.symlink_to(root / cache.SAMPLE / "InnoFlowSampleAppPackage/Package.resolved")
            with mock.patch.object(cache, "command", side_effect=[tracked, ""]), self.assertRaisesRegex(ValueError, "symlinked"):
                cache.repository_inputs(root)

    def test_toolchain_collects_each_sdk_version_and_build_without_building(self):
        commands = []

        def output(*args):
            commands.append(args)
            if args == ("xcodebuild", "-showsdks"):
                return "macOS SDKs:\n\tmacOS 26.6 -sdk macosx26.6\niOS SDKs:\n\tiOS 26.6 -sdk iphoneos26.6"
            if args[-1] == "--show-sdk-version":
                return "26.6"
            if args[-1] == "--show-sdk-build-version":
                return "25G42"
            return {("swift", "--version"): toolchain()["swift"],
                    ("xcrun", "--find", "swift"): toolchain()["swift-path"],
                    ("xcodebuild", "-version"): toolchain()["xcode"],
                    ("xcode-select", "-p"): toolchain()["developer-dir"],
                    ("sw_vers", "-productVersion"): "26.6", ("sw_vers", "-buildVersion"): "25G42",
                    ("uname", "-m"): "arm64"}[args]

        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(cache, "command", side_effect=output):
            result = cache.toolchain_identity()
        self.assertEqual(set(result["sdks"]), {"macosx26.6", "iphoneos26.6"})
        self.assertIn(("xcrun", "--sdk", "iphoneos26.6", "--show-sdk-build-version"), commands)
        self.assertFalse(any("test" in command or "build" in command or "resolve" in command for command in commands))
        for listing in ("", "macOS -sdk macosx26.6\nmacOS duplicate -sdk macosx26.6"):
            with mock.patch.object(cache, "command", return_value=listing), self.assertRaises(ValueError):
                cache.toolchain_identity()


class ObservationTests(unittest.TestCase):
    def test_cold_cache_is_empty_and_only_allowed_download_trees_are_observed(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            self.assertEqual(cache.observations(home), {})
            mirror = home / "Library/Caches/org.swift.swiftpm/repositories/swift-syntax/HEAD"
            mirror.parent.mkdir(parents=True)
            mirror.write_text("ref: refs/heads/main")
            for excluded in (".build/SwiftSyntax.build/product.o", "Library/Developer/Xcode/DerivedData/product.o",
                             "Library/Caches/org.swift.swiftpm/security/fingerprint.json"):
                path = home / excluded
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("must not be observed")
            first = cache.observations(home)
            self.assertEqual(list(first), ["repositories/swift-syntax/HEAD"])
            cache.validate_observations(first)
            mirror.write_text("changed")
            self.assertNotEqual(first, cache.observations(home))
            link = mirror.parent / "outside"
            link.symlink_to(home / ".build", target_is_directory=True)
            observed = cache.observations(home)
            self.assertEqual(len(observed), 2)
            self.assertEqual(observed["repositories/swift-syntax/outside"][0], "symlink")
            self.assertNotIn("product.o", json.dumps(observed))

    def test_invalid_cache_roots_metadata_and_state_paths_fail_closed(self):
        for value in (None, [], {"../outside": ["file", 1, 1]}, {".build/file.o": ["file", 1, 1]},
                      {"repositories": ["file", 1, 1]}, {"repositories/file": ["file", -1, 1]},
                      {"repositories/file": ["file", True, 1]}, {"repositories/file": ["file", 1, -1]},
                      {"repositories/file": ["file", 1]}, {"repositories/file": ["object", 1, 1]}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                cache.validate_observations(value)
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            base = home / "Library/Caches/org.swift.swiftpm"
            base.mkdir(parents=True)
            (base / "repositories").symlink_to(home, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlinked cache root"):
                cache.observations(home)
            (base / "repositories").unlink()
            (base / "repositories").write_text("not a directory")
            with self.assertRaisesRegex(ValueError, "not a directory"):
                cache.observations(home)
            target, state = home / "target", home / "state"
            target.write_text("untouched")
            state.symlink_to(target)
            with self.assertRaises(ValueError):
                cache.write_state(state, {})
            self.assertEqual(target.read_text(), "untouched")


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.state, self.output, self.summary = (self.root / name for name in ("state.json", "output", "summary"))
        self.now = 100.0
        self.inputs = inputs()
        self.toolchain = toolchain()
        self.entries = {}
        patches = [
            mock.patch.dict(os.environ, {"HOME": str(self.root), "GITHUB_OUTPUT": str(self.output),
                "GITHUB_STEP_SUMMARY": str(self.summary), "DEPENDENCY_CACHE_HIT": "",
                "GITHUB_RUN_ID": "10", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_JOB": "tests"}, clear=True),
            mock.patch.object(cache, "repository_inputs", side_effect=lambda root: self.inputs),
            mock.patch.object(cache, "toolchain_identity", side_effect=lambda: self.toolchain),
            mock.patch.object(cache, "observations", side_effect=lambda home: self.entries),
            mock.patch.object(cache.time, "time", side_effect=lambda: self.now),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def run_cli(self, command, profile="tests", variant="default"):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = cache.main([command, "--root", str(self.root), "--state", str(self.state),
                                 "--profile", profile, "--variant", variant])
        return result, stdout.getvalue(), stderr.getvalue()

    def succeed(self, command, **kwargs):
        result, output, error = self.run_cli(command, **kwargs)
        self.assertEqual(result, 0, error)
        return output

    def mutate_state(self, mutation):
        data = json.loads(self.state.read_text())
        mutation(data)
        self.state.write_text(json.dumps(data))

    def test_cold_and_warm_observations_never_imply_verification(self):
        for hit in ("", "false", "true"):
            with self.subTest(hit=hit):
                self.now = 100.0
                os.environ["DEPENDENCY_CACHE_HIT"] = hit
                self.succeed("fingerprint")
                self.assertIn("dependency-key=innoflow-swiftpm-deps-v1-tests-default-", self.output.read_text())
                self.assertIn("dependency-paths<<CACHE_PATHS", self.output.read_text())
                self.entries = {"prebuilts/archive.zip": ["file", 42, 100]} if hit == "true" else {}
                self.now = 102.5
                self.succeed("restored")
                self.now = 110.0
                self.entries = {**self.entries, "repositories/new/HEAD": ["file", 3, 100]}
                report = json.loads(self.succeed("report"))
                self.assertEqual(report["dependency_cache_hit"], hit)
                self.assertEqual(report["restore_elapsed_seconds"], 2.5)
                self.assertEqual(report["validation_elapsed_seconds"], 7.5)
                self.assertEqual(report["verification"], "not-evaluated-by-cache")
                self.assertEqual(report["restored_entries_unchanged"], 1 if hit == "true" else 0)
                self.assertIn("not verification", self.summary.read_text())
                self.assertNotEqual(self.run_cli("report")[0], 0)

    def test_matrix_profile_survives_json_state_round_trip(self):
        for command in ("fingerprint", "restored", "report"):
            self.succeed(command, profile="focused-runtime-tests", variant="watchOS")

    def test_missing_malformed_or_wrong_phase_observations_fail_closed(self):
        for command in ("restored", "report"):
            self.assertNotEqual(self.run_cli(command)[0], 0)
        self.succeed("fingerprint")
        self.assertNotEqual(self.run_cli("report")[0], 0)
        for hit in (None, "TRUE", "success", "null"):
            if hit is None:
                os.environ.pop("DEPENDENCY_CACHE_HIT", None)
            else:
                os.environ["DEPENDENCY_CACHE_HIT"] = hit
            self.assertNotEqual(self.run_cli("restored")[0], 0)
        os.environ["DEPENDENCY_CACHE_HIT"] = "false"
        self.succeed("restored")
        self.assertNotEqual(self.run_cli("restored")[0], 0)
        for mutation in (
            lambda data: data.pop("restored"), lambda data: data.update(restored=[]),
            lambda data: data.update(restored={".build/a.o": ["file", 2, 1]}),
            lambda data: data.update(dependency_hit="success"), lambda data: data.pop("dependency_hit"),
            lambda data: data.update(restore_seconds=-1), lambda data: data.update(restore_seconds=True),
            lambda data: data.update(restore_seconds=float("nan")), lambda data: data.pop("build_started"),
            lambda data: data.update(build_started=111), lambda data: data.update(started="yesterday"),
            lambda data: data.update(schema=True), lambda data: data.update(fingerprint={}),
            lambda data: data.update(context={}), lambda data: data.update(phase="reported"),
        ):
            self.succeed("fingerprint")
            self.succeed("restored")
            self.mutate_state(mutation)
            self.assertNotEqual(self.run_cli("report")[0], 0)
        for malformed in ("{", "null", "[]", '{"schema": 1, "schema": 1}'):
            self.state.write_text(malformed)
            self.assertNotEqual(self.run_cli("report")[0], 0)

    def test_changed_inputs_toolchain_profile_or_run_context_reject_observations(self):
        for command in ("restored", "report"):
            for change in ("lock", "compiler", "profile", "run-id", "run-attempt"):
                with self.subTest(command=command, change=change):
                    self.inputs, self.toolchain = inputs(), toolchain()
                    os.environ.update(GITHUB_RUN_ID="10", GITHUB_RUN_ATTEMPT="1")
                    self.succeed("fingerprint")
                    if command == "report":
                        self.succeed("restored")
                    profile = "tests"
                    if change == "lock":
                        self.inputs["Package.resolved"] += "\n"
                    elif change == "compiler":
                        self.toolchain["swift"] = self.toolchain["swift"].replace("6.3.0.4.1", "6.3.0.4.2")
                    elif change == "profile":
                        profile = "coverage"
                    elif change == "run-id":
                        os.environ["GITHUB_RUN_ID"] = "11"
                    else:
                        os.environ["GITHUB_RUN_ATTEMPT"] = "2"
                    self.assertNotEqual(self.run_cli(command, profile=profile)[0], 0)

    def test_tool_command_failures_empty_inputs_and_missing_output_fail_closed(self):
        with mock.patch.object(cache, "toolchain_identity", side_effect=subprocess.CalledProcessError(1, ["swift", "--version"])):
            self.assertNotEqual(self.run_cli("fingerprint")[0], 0)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.output.exists())
        self.inputs["Package.resolved"] = ""
        self.assertNotEqual(self.run_cli("fingerprint")[0], 0)
        self.inputs = inputs()
        os.environ.pop("GITHUB_OUTPUT")
        self.assertNotEqual(self.run_cli("fingerprint")[0], 0)
        self.assertFalse(self.state.exists())


class CLIIntegrationTests(unittest.TestCase):
    def test_real_cli_ignores_build_inputs_and_state_survives_build_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            root, home, binaries = (base / name for name in ("checkout", "home", "bin"))
            for directory in (root, home, binaries):
                directory.mkdir()
            for relative, contents in inputs().items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            (root / ".gitignore").write_text(".build/\nbuild/\n")
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            commands = {
                "swift": "printf '%s\\n' 'Apple Swift version 6.3 (swiftlang-6.3.0.4.1 clang-1700.6.5.2)'",
                "xcodebuild": "if [ \"$1\" = '-version' ]; then printf '%s\\n' 'Xcode 26.6' 'Build version 17G42'; else printf '%s\\n' 'macOS 26.6 -sdk macosx26.6' 'iOS 26.6 -sdk iphoneos26.6'; fi",
                "xcrun": "if [ \"$1\" = '--find' ]; then echo /fixture/Xcode.app/Contents/Developer/usr/bin/swift; elif [ \"$3\" = '--show-sdk-version' ]; then echo 26.6; elif [ \"$3\" = '--show-sdk-build-version' ]; then echo 25G42; else exit 1; fi",
                "sw_vers": "if [ \"$1\" = '-productVersion' ]; then echo 26.6; else echo 25G42; fi",
                "uname": "echo arm64", "xcode-select": "echo /fixture/Xcode.app/Contents/Developer",
            }
            for name, command in commands.items():
                executable = binaries / name
                executable.write_text("#!/bin/sh\nset -eu\n" + command + "\n")
                executable.chmod(0o755)
            env = {**os.environ, "HOME": str(home), "PATH": str(binaries) + ":" + os.environ["PATH"],
                   "GITHUB_OUTPUT": str(base / "outputs"), "GITHUB_STEP_SUMMARY": str(base / "summary"),
                   "DEPENDENCY_CACHE_HIT": "false", "DEVELOPER_DIR": "/fixture/Xcode.app/Contents/Developer"}
            for phase in ("fingerprint", "restored", "report"):
                if phase == "restored":
                    generated = root / ".build/checkouts/dependency/Package.swift"
                    generated.parent.mkdir(parents=True)
                    generated.write_text("ignored generated manifest")
                elif phase == "report":
                    shutil.rmtree(root / ".build")
                    generated = root / cache.SAMPLE / "InnoFlowSampleAppPackage/.build/checkouts/dependency/Package.swift"
                    generated.parent.mkdir(parents=True)
                    generated.write_text("ignored sample dependency manifest")
                run = subprocess.run([sys.executable, "-B", str(SCRIPT), phase, "--root", str(root),
                                      "--profile", "package-builds", "--variant", "iOS"],
                                     env=env, text=True, capture_output=True)
                self.assertEqual(run.returncode, 0, (phase, run.stdout, run.stderr))
            data = json.loads((root / "build/ci-cache.json").read_text())
            self.assertEqual(data["phase"], "reported")
            self.assertEqual(data["report"]["verification"], "not-evaluated-by-cache")
            self.assertFalse((root / ".build").exists())


class WorkflowWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ruby/Psych is already required by CI policy; do not add a Python YAML dependency.
        result = subprocess.check_output([
            "ruby", "-rjson", "-ryaml", "-e",
            "puts JSON.generate(ARGV.map { |p| YAML.safe_load(File.read(p), aliases: false) })",
            str(ROOT / ".github/workflows/ci.yml"), str(ROOT / ".github/workflows/coverage.yml"),
        ], text=True)
        cls.ci, cls.coverage = json.loads(result)

    def assert_wiring(self, ci, coverage):
        expected = set(cache.PROFILES) - {"coverage"}
        jobs = ci["jobs"]
        cached = {name for name, job in jobs.items() if any(
            step.get("uses", "").startswith("actions/cache@") for step in job.get("steps", []))}
        self.assertEqual(cached, expected)
        for profile, job in [(name, jobs[name]) for name in sorted(expected)] + [("coverage", coverage["jobs"]["coverage"])]:
            steps = job["steps"]
            suffix = " --profile " + profile
            if "platforms" in cache.PROFILES[profile]:
                suffix += " --variant '${{ matrix.platform }}'"
            elif "versions" in cache.PROFILES[profile]:
                suffix += " --variant '${{ matrix.syntax }}'"
            cache_steps = [step for step in steps if step.get("uses", "").startswith("actions/cache@")]
            self.assertEqual(len(cache_steps), 1)
            restore = cache_steps[0]
            self.assertEqual(restore["uses"], "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9")
            self.assertEqual(restore.get("id"), "dependency-cache")
            self.assertEqual(restore.get("with"), {
                "path": "${{ steps.cache-inputs.outputs.dependency-paths }}",
                "key": "${{ steps.cache-inputs.outputs.dependency-key }}",
            })
            indexes = {}
            for phase in ("fingerprint", "restored", "report"):
                candidates = [step for step in steps if "ci-cache.py " + phase in step.get("run", "")]
                self.assertEqual(len(candidates), 1)
                step = candidates[0]
                self.assertEqual(step["run"], "python3 -B scripts/ci-cache.py " + phase + suffix)
                self.assertNotIn("continue-on-error", step)
                if phase == "fingerprint":
                    self.assertEqual(step.get("id"), "cache-inputs")
                    self.assertNotIn("if", step)
                elif phase == "restored":
                    self.assertNotIn("if", step)
                    self.assertEqual(step.get("env"), {"DEPENDENCY_CACHE_HIT": "${{ steps.dependency-cache.outputs.cache-hit }}"})
                else:
                    self.assertEqual(step.get("if"), "always()")
                indexes[phase] = steps.index(step)
            self.assertNotIn("continue-on-error", job)
            self.assertNotIn("continue-on-error", restore)
            self.assertNotIn("if", restore)
            self.assertLess(indexes["fingerprint"], steps.index(restore))
            self.assertLess(steps.index(restore), indexes["restored"])
            self.assertLess(indexes["restored"], indexes["report"])
            self.assertTrue(any(step.get("run") for step in steps[indexes["restored"] + 1:indexes["report"]]))
            for step in steps:
                self.assertNotIn("cache-hit", step.get("if", ""))
                self.assertNotIn("continue-on-error", step)
            if profile == "swift-syntax-compatibility":
                audit = next(index for index, step in enumerate(steps) if step.get("name") == "Resolve and verify audited SwiftSyntax")
                self.assertLess(audit, indexes["fingerprint"])
                for text in ("swift package resolve swift-syntax", "SYNTAX_VERSION", "SYNTAX_REVISION"):
                    self.assertIn(text, steps[audit]["run"])

    def test_complete_workflow_wiring_uses_exact_keys_and_blocking_observations(self):
        self.assert_wiring(self.ci, self.coverage)

    def test_workflow_negative_controls_reject_broad_keys_bad_matrix_and_bypasses(self):
        mutations = [
            lambda jobs: jobs["tests"]["steps"].append({"uses": "actions/cache@other"}),
            lambda jobs: next(s for s in jobs["tests"]["steps"] if s.get("id") == "dependency-cache")["with"].update(path=".build"),
            lambda jobs: next(s for s in jobs["tests"]["steps"] if s.get("id") == "dependency-cache")["with"].update({"restore-keys": "swiftpm-"}),
            lambda jobs: next(s for s in jobs["tests"]["steps"] if s.get("id") == "dependency-cache").update({"continue-on-error": True}),
            lambda jobs: next(s for s in jobs["tests"]["steps"] if "ci-cache.py report" in s.get("run", "")).pop("if"),
            lambda jobs: next(s for s in jobs["tests"]["steps"] if "ci-cache.py report" in s.get("run", "")).update(run="python3 -B scripts/ci-cache.py report --profile tests || true"),
            lambda jobs: next(s for s in jobs["package-builds"]["steps"] if s.get("id") == "cache-inputs").update(run="python3 -B scripts/ci-cache.py fingerprint --profile package-builds --variant '${ matrix.platform }'"),
            lambda jobs: next(s for s in jobs["tests"]["steps"] if s.get("name") == "Verify macro source fallback").update({"if": "steps.dependency-cache.outputs.cache-hit != 'true'"}),
            lambda jobs: jobs["tests"].update({"continue-on-error": True}),
        ]
        for mutation in mutations:
            ci = copy.deepcopy(self.ci)
            mutation(ci["jobs"])
            with self.assertRaises(AssertionError):
                self.assert_wiring(ci, self.coverage)

    def test_source_fallback_coverage_sanitizers_and_compatibility_still_execute(self):
        runs = lambda job: "\n".join(step.get("run", "") for step in job["steps"])
        jobs = self.ci["jobs"]
        self.assertIn("--disable-experimental-prebuilts", runs(jobs["tests"]))
        self.assertIn("swift test", runs(jobs["tests"]))
        for sanitizer in ("thread", "address"):
            self.assertIn("--sanitize=" + sanitizer, runs(jobs[sanitizer + "-sanitizer"]))
        self.assertIn("--filter 'InnoFlowMacrosTests|CompileContractTests'", runs(jobs["swift-syntax-compatibility"]))
        self.assertIn("--disable-automatic-resolution", runs(jobs["sample-tests"]))
        self.assertIn("scripts/run-coverage.sh", runs(self.coverage["jobs"]["coverage"]))
        self.assertIn("--enable-code-coverage", (ROOT / "scripts/run-coverage.sh").read_text())
        for workflow in ("cd.yml", "release-evidence.yml", "release-preflight.yml", "asan.yml"):
            contents = (ROOT / ".github/workflows" / workflow).read_text()
            self.assertNotIn("ci-cache.py", contents)
            self.assertNotIn("actions/cache@", contents)


if __name__ == "__main__":
    unittest.main()
