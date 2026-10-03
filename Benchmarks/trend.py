#!/usr/bin/env python3
"""Advisory Apple S1–S6 trend capture. Never substitutes for release/adoption gates."""

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

SCHEMA_VERSION = 1
PAIRS = 7
WARMUPS = 2
COUNTS = {"S1": 100_000, "S2": 20_000, "S3": 2_000,
          "S4": 30_000, "S5": 100_000, "S6": 2_000}
PACKAGES = {
    "innoflow": ("Benchmarks/InnoFlowBenchmarks", "InnoFlowBenchmarks"),
    "tca": ("Benchmarks/Comparison", "TCAComparison"),
}
LIMITATION = (
    "Workload-specific, non-blocking trend only; no universal framework ranking, "
    "regression verdict, optimization-adoption verdict, or release evidence. "
    "S4 compares retained SelectedStore and Combine-backed ViewStore read models; "
    "their implementations differ. Seven pairs do not establish a stable population estimate."
)


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def raw_bytes(value):
    return value if isinstance(value, bytes) else (value or "").encode()


def is_swift_640_release(version):
    # Official 6.4.0 distributions can print 6.4 / swift-6.4-RELEASE.
    # Accept that spelling, not a later patch, snapshot, or Apple Swift build.
    return bool(re.search(r"\bSwift version 6\.4(?:\.0)?(?:\s|\()", version)
                and re.search(r"\(swift-6\.4(?:\.0)?-RELEASE(?:[ )])", version))


def run_command(command, output, name, repo, env, timeout):
    """Save raw streams and a receipt even on timeout or launch failure."""
    log = output / "logs" / name
    log.parent.mkdir(parents=True, exist_ok=True)
    receipt = {"command": [str(x) for x in command], "cwd": str(repo),
               "started_at": utc_now(), "timeout_seconds": timeout, "status": "running"}
    write_json(log.with_suffix(".json"), receipt)
    stdout, stderr = b"", b""
    try:
        completed = subprocess.run(command, cwd=repo, env=env, capture_output=True, timeout=timeout)
        stdout, stderr = completed.stdout, completed.stderr
        receipt.update(returncode=completed.returncode, status="complete")
        if completed.returncode:
            raise RuntimeError(f"{name}: exit {completed.returncode}; see raw logs")
        return stdout.decode("utf-8", errors="strict").strip()
    except subprocess.TimeoutExpired as error:
        stdout, stderr = raw_bytes(error.stdout), raw_bytes(error.stderr)
        receipt.update(status="timeout", error=str(error))
        raise RuntimeError(f"{name}: timed out; partial raw logs preserved") from error
    except BaseException as error:
        receipt.update(status="failed", error=str(error))
        raise
    finally:
        log.with_suffix(".stdout").write_bytes(stdout)
        log.with_suffix(".stderr").write_bytes(stderr)
        receipt["finished_at"] = utc_now()
        write_json(log.with_suffix(".json"), receipt)


def expected_checksum(scenario):
    count = COUNTS[scenario]
    return {"S1": count, "S2": count * 11, "S3": count,
            "S4": count + 6_650, "S5": count - 1, "S6": count * 2}[scenario]


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def parse_measurement(stdout, scenario):
    lines = [line for line in stdout.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError("Expected exactly one nonempty JSON result line")
    data = json.loads(lines[0], object_pairs_hook=unique_object)
    if not isinstance(data, dict):
        raise ValueError("Expected a JSON object")
    if data.get("status") != "measured" or data.get("scenario") != scenario:
        raise ValueError("Unsupported, failed, or mismatched scenario")
    if type(data.get("iterations")) is not int or data["iterations"] != COUNTS[scenario]:
        raise ValueError("Mismatched iteration count")
    if type(data.get("checksum")) is not int or data["checksum"] != expected_checksum(scenario):
        raise ValueError("Incorrect scenario checksum")
    ns = data.get("ns")
    if type(ns) not in (int, float) or not math.isfinite(ns) or ns <= 0:
        raise ValueError("Timing must be positive and finite")
    return {key: data[key] for key in ("scenario", "iterations", "ns", "checksum", "status")}


def schedule():
    # A = InnoFlow, B = TCA. Alternate initial order by scenario so the
    # complete six-scenario cohort has exactly 21 measured AB and 21 BA pairs.
    for scenario_index, scenario in enumerate(COUNTS):
        for phase, count in (("warmup", WARMUPS), ("measured", PAIRS)):
            for pair in range(count):
                sides = list(PACKAGES)
                if (scenario_index + pair) % 2:
                    sides.reverse()
                for side in sides:
                    yield scenario, phase, pair, side


def summarize(rows):
    wanted = list(schedule())
    actual = [(r.get("scenario"), r.get("phase"), r.get("pair"), r.get("side")) for r in rows]
    if actual != wanted:
        raise ValueError("Incomplete, duplicated, unexpected, or reordered fixed cohort")
    for row in rows:
        if type(row.get("pair")) is not int:
            raise ValueError("Pair identifiers must be integers")
        parse_measurement(json.dumps(row), row["scenario"])
    result = {}
    for scenario, iterations in COUNTS.items():
        sides = {
            side: [r["ns"] for r in rows if r["scenario"] == scenario
                   and r["phase"] == "measured" and r["side"] == side]
            for side in PACKAGES
        }
        ratios = [b / a for a, b in zip(sides["innoflow"], sides["tca"])]
        if not all(math.isfinite(ratio) and ratio > 0 for ratio in ratios):
            raise ValueError("Paired ratios must be positive and finite")
        result[scenario] = {
            "iterations_per_process": iterations,
            "pairs": PAIRS,
            "ns_per_iteration": {
                side: {"median": statistics.median(values) / iterations,
                       "min": min(values) / iterations, "max": max(values) / iterations}
                for side, values in sides.items()
            },
            "paired_tca_over_innoflow_ratios": ratios,
            "median_paired_tca_over_innoflow_ratio": statistics.median(ratios),
        }
    return result


def source_files(repo):
    files = {repo / "Package.swift", repo / "Benchmarks/trend.py"}
    if (repo / "Package.resolved").is_file():
        files.add(repo / "Package.resolved")
    files.update((repo / "Sources").rglob("*.swift"))
    for relative, _ in PACKAGES.values():
        files.add(repo / relative / "Package.swift")
        files.update((repo / relative / "Sources").rglob("*.swift"))
    return sorted(files)


def snapshot_sources(repo, output):
    hashes = {}
    for path in source_files(repo):
        relative = path.relative_to(repo)
        destination = output / "sources" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        hashes[str(relative)] = sha256(destination)
    return hashes


def snapshot_resolutions(repo, output, stage):
    results = {}
    for side, (relative, _) in PACKAGES.items():
        source = repo / relative / "Package.resolved"
        entry = {"path": str(source.relative_to(repo)), "exists": source.is_file()}
        results[side] = entry
        if not source.is_file():
            continue
        target = output / "resolutions" / stage / side / "Package.resolved"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        entry.update(sha256=sha256(target), artifact=str(target.relative_to(output)))
        try:
            resolution = json.loads(target.read_text(), object_pairs_hook=unique_object)
            pins = resolution.get("pins")
            if not isinstance(pins, list) or not pins:
                raise ValueError("Resolved manifest must contain nonempty pins")
            identities = set()
            for pin in pins:
                identity = pin["identity"]
                if identity in identities or not re.fullmatch(r"[0-9a-f]{40}", pin["state"]["revision"]):
                    raise ValueError("Duplicate identity or invalid resolved revision")
                identities.add(identity)
            if side == "tca":
                tca = [p for p in pins if p["identity"] == "swift-composable-architecture"]
                if len(tca) != 1 or tca[0]["state"].get("version") != "1.26.2":
                    raise ValueError("TCA must resolve exactly to 1.26.2")
            entry.update(pins=pins, valid=True)
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            entry.update(valid=False, error=str(error))
    return results


def report(output, manifest, results=None):
    complete = manifest["status"] == "complete"
    summary = {"schema_version": SCHEMA_VERSION, "status": manifest["status"],
               "cohort_complete": complete, "timing_is_advisory": True,
               "limitations": LIMITATION, "publication_ready": manifest.get("publication_ready", False),
               "errors": manifest.get("errors", []), "results": results if complete else {}}
    write_json(output / "summary.json", summary)
    lines = ["# Benchmark trend (non-blocking)", "", f"Capture status: **{manifest['status']}**", "", LIMITATION, ""]
    if complete:
        lines += ["All six scenarios have seven validated pairs plus two paired warmups.",
                  "Units are ns per scenario iteration; S2 has eleven reductions per iteration.", "",
                  "| Scenario | InnoFlow median | TCA median | Paired median TCA / InnoFlow |",
                  "| --- | ---: | ---: | ---: |"]
        for scenario, result in results.items():
            values = result["ns_per_iteration"]
            lines.append(f"| {scenario} | {values['innoflow']['median']:.3f} | {values['tca']['median']:.3f} | "
                         f"{result['median_paired_tca_over_innoflow_ratio']:.3f} |")
        lines += ["", "A ratio describes only these paired workloads on this host."]
        if not manifest["publication_ready"]:
            lines += ["", "Provisional capture: a clean source revision and committed, unchanged "
                      "transitive pins for both packages are required before reproducible publication."]
    else:
        lines += ["No timing metrics are published for an incomplete cohort. See raw logs and manifest.json."]
    lines += ["", *[f"- {error}" for error in manifest.get("errors", [])]]
    (output / "summary.md").write_text("\n".join(lines) + "\n")


def capture(repo, output):
    output.mkdir(parents=True, exist_ok=False)
    manifest = {"schema_version": SCHEMA_VERSION, "status": "incomplete", "started_at": utc_now(),
                "pairs": PAIRS, "paired_warmups": WARMUPS, "counts": COUNTS,
                "required_swift_version": "6.4.0-RELEASE", "required_xcode_version": "26.6",
                "innoflow_package_path": str(repo),
                "required_scenarios": list(COUNTS), "validated_processes": 0,
                "expected_processes": len(list(schedule())), "errors": [],
                "limitations": LIMITATION, "publication_ready": False,
                "host": {"platform": platform.platform(), "machine": platform.machine(),
                         "processor": platform.processor(), "python": platform.python_version()},
                "environment": {key: os.environ.get(key) for key in (
                    "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS", "SWIFT_EXEC", "RUNNER_OS", "RUNNER_ARCH",
                    "ImageOS", "ImageVersion", "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")}}
    write_json(output / "manifest.json", manifest)
    report(output, manifest)
    env = dict(os.environ, INNOFLOW_BENCHMARK_PACKAGE=str(repo))
    results, rows = None, []

    def command(args, name, timeout=60):
        return run_command(args, output, name, repo, env, timeout)

    try:
        manifest["repo_sha"] = command(["git", "rev-parse", "HEAD"], "repo-sha")
        manifest["repo_description"] = command(["git", "describe", "--tags", "--always", "--dirty"], "repo-description")
        manifest["dirty_status"] = command(["git", "status", "--porcelain", "--untracked-files=all"], "source-status")
        command(["git", "diff", "--binary", "HEAD"], "source-diff")
        manifest["source_sha256"] = snapshot_sources(repo, output)
        manifest["resolutions_before"] = snapshot_resolutions(repo, output, "before")
        tracked = set(command(["git", "ls-files"], "tracked-files").splitlines())
        manifest["resolved_manifests_committed"] = {
            side: str(Path(relative) / "Package.resolved") in tracked
            for side, (relative, _) in PACKAGES.items()
        }
        manifest["swift_version"] = command(["swift", "--version"], "swift-version")
        setup_receipt = output.parent / "toolchain/receipt.json"
        if setup_receipt.is_file():
            manifest["toolchain_setup_evidence"] = {"path": "../toolchain/receipt.json",
                                                    "sha256": sha256(setup_receipt)}
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("Matched S1–S6 trend requires an Apple-silicon macOS host; no Linux substitution")
        manifest["xcode_version"] = command(["xcodebuild", "-version"], "xcode-version")
        if manifest["xcode_version"].splitlines()[0] != "Xcode 26.6":
            raise RuntimeError("This cohort requires Xcode 26.6; no toolchain substitution")
        manifest["hardware"] = command(["sysctl", "hw.model", "hw.memsize", "hw.ncpu"], "hardware")
        manifest["swift_command_path"] = shutil.which("swift", path=env.get("PATH"))
        manifest["xcrun_swift_path"] = command(["xcrun", "--find", "swift"], "xcrun-swift-path")
        manifest["macos_sdk_path"] = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "macos-sdk-path")
        manifest["macos_sdk_version"] = command(["xcrun", "--sdk", "macosx", "--show-sdk-version"], "macos-sdk-version")
        version = re.search(r"Swift version (\d+)\.(\d+)", manifest["swift_version"])
        if not version:
            raise RuntimeError("Cannot identify the Swift compiler version")
        actual_version = tuple(map(int, version.groups()))
        manifest["package_tools_versions"] = {}
        for side, (relative, _) in PACKAGES.items():
            match = re.search(r"swift-tools-version:\s*(\d+)\.(\d+)", (repo / relative / "Package.swift").read_text())
            if not match:
                raise RuntimeError(f"{side}: missing swift-tools-version")
            required = tuple(map(int, match.groups()))
            manifest["package_tools_versions"][side] = ".".join(match.groups())
            if actual_version < required:
                raise RuntimeError(f"{side} needs Swift {required[0]}.{required[1]}; selected compiler is "
                                   f"{actual_version[0]}.{actual_version[1]}. Apple compilation remains pending")
        if actual_version != (6, 4) or not is_swift_640_release(manifest["swift_version"]):
            raise RuntimeError("This matched cohort requires the official Swift 6.4.0-RELEASE toolchain; no substitution")
        binaries = {}
        manifest["binaries"] = {}
        for side, (relative, product) in PACKAGES.items():
            package = repo / relative
            command(["swift", "package", "--package-path", str(package), "resolve"], f"{side}-resolve", 900)
            build = ["swift", "build", "--package-path", str(package), "--configuration", "release",
                     "--scratch-path", str(output / "build" / side)]
            command([*build, "--jobs", "2", "--product", product], f"{side}-build", 1200)
            bin_path = command([*build, "--show-bin-path"], f"{side}-bin-path")
            executable = (Path(bin_path) / product).resolve(strict=True)
            if not executable.is_file() or not os.access(executable, os.X_OK):
                raise RuntimeError(f"{side}: executable is missing or not executable")
            binaries[side] = executable
            manifest["binaries"][side] = {"path": str(executable), "sha256": sha256(executable)}
        manifest["resolutions_built"] = snapshot_resolutions(repo, output, "built")
        if not all(entry.get("valid") for entry in manifest["resolutions_built"].values()):
            raise RuntimeError("Both valid resolved manifests are required before measuring")
        for side, before in manifest["resolutions_before"].items():
            if before["exists"] and before.get("sha256") != manifest["resolutions_built"][side]["sha256"]:
                raise RuntimeError(f"{side}: existing resolved manifest changed during build; review pins before measuring")
        write_json(output / "manifest.json", manifest)
        # Both release builds finish before any measured process starts. Never
        # launch simultaneous processes, builds, or background benchmark work.
        for scenario, phase, pair, side in schedule():
            name = f"{scenario}-{phase}-{pair + 1:02d}-{side}"
            stdout = command([str(binaries[side]), scenario, str(COUNTS[scenario])], name, 180)
            row = {**parse_measurement(stdout, scenario), "phase": phase, "pair": pair, "side": side,
                   "ordinal": len(rows), "log": f"logs/{name}"}
            rows.append(row)
            with (output / "samples.jsonl").open("a") as stream:
                stream.write(json.dumps(row, allow_nan=False) + "\n")
            manifest["validated_processes"] = len(rows)
            write_json(output / "manifest.json", manifest)
        results = summarize(rows)
        if manifest["source_sha256"] != {str(path.relative_to(repo)): sha256(path) for path in source_files(repo)}:
            raise RuntimeError("Benchmark or library sources changed during capture")
        for side, executable in binaries.items():
            if sha256(executable) != manifest["binaries"][side]["sha256"]:
                raise RuntimeError(f"{side}: executable changed during capture")
        manifest["resolutions_after"] = snapshot_resolutions(repo, output, "after")
        if manifest["resolutions_after"] != {
            side: {**entry, "artifact": entry["artifact"].replace("/built/", "/after/")}
            for side, entry in manifest["resolutions_built"].items()
        }:
            raise RuntimeError("Resolved manifests changed during capture")
        manifest["publication_ready"] = (not manifest["dirty_status"]
                                         and all(manifest["resolved_manifests_committed"].values()))
        manifest["status"] = "complete"
    except BaseException as error:
        manifest["errors"].append(f"{type(error).__name__}: {error}")
    finally:
        # Preserve partial resolution evidence even when dependency resolution or
        # compilation fails. Build products are intentionally outside artifacts.
        try:
            manifest["resolutions_final"] = snapshot_resolutions(repo, output, "final")
        except (OSError, ValueError) as error:
            manifest["status"] = "incomplete"
            manifest["publication_ready"] = False
            manifest["errors"].append(f"Final resolution evidence: {error}")
        manifest["finished_at"] = utc_now()
        write_json(output / "manifest.json", manifest)
        report(output, manifest, results)
    print(f"Benchmark trend: {manifest['status']}; {output / 'summary.json'}")
    return 0 if manifest["status"] == "complete" else 1


def self_test():
    """Pure Python controls: no Swift, network, benchmark process, or build."""
    import tempfile
    import unittest
    from unittest.mock import patch

    class Controls(unittest.TestCase):
        def test_official_640_release_spellings_only(self):
            for version in ("Swift version 6.4 (swift-6.4-RELEASE)",
                            "Apple Swift version 6.4.0 (swift-6.4.0-RELEASE)"):
                self.assertTrue(is_swift_640_release(version))
            for version in ("Swift version 6.4.1 (swift-6.4.1-RELEASE)",
                            "Swift version 6.4 (swift-6.4-DEVELOPMENT-SNAPSHOT)",
                            "Apple Swift version 6.4 (swiftlang-6.4)",
                            "Swift version 6.5 (swift-6.4-RELEASE)"):
                self.assertFalse(is_swift_640_release(version))

        def valid_rows(self):
            return [{"scenario": scenario, "phase": phase, "pair": pair, "side": side,
                     "iterations": COUNTS[scenario], "checksum": expected_checksum(scenario),
                     "ns": 100 if side == "innoflow" else 200, "status": "measured"}
                    for scenario, phase, pair, side in schedule()]

        def test_fixed_complete_cohort(self):
            rows = self.valid_rows()
            self.assertEqual(len(rows), 108)
            results = summarize(rows)
            self.assertEqual(set(results), set(COUNTS))
            self.assertTrue(all(r["median_paired_tca_over_innoflow_ratio"] == 2 for r in results.values()))
            starts = [side for _, phase, _, side in list(schedule())[::2] if phase == "measured"]
            self.assertEqual(starts.count("innoflow"), 21)
            self.assertEqual(starts.count("tca"), 21)

        def test_missing_duplicate_and_reordered_cohort(self):
            rows = self.valid_rows()
            for invalid in (rows[:-1], rows + [rows[0]], rows[1:] + rows[:1],
                            [r for r in rows if r["scenario"] != "S5"],
                            [r for r in rows if r["phase"] != "warmup"]):
                with self.subTest(size=len(invalid)), self.assertRaises(ValueError):
                    summarize(invalid)

        def test_invalid_results(self):
            row = self.valid_rows()[0]
            for key, value in (("ns", 0), ("ns", -1), ("ns", True), ("ns", float("inf")),
                               ("ns", float("nan")), ("iterations", True), ("iterations", 2),
                               ("checksum", True), ("checksum", 0), ("scenario", "S5"),
                               ("status", "unsupported-platform")):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    parse_measurement(json.dumps({**row, key: value}), "S1")
            for stdout in ("", "[]", "{}", json.dumps(row) + "\nwarning", '{"ns":1,"ns":2}'):
                with self.subTest(stdout=stdout), self.assertRaises(ValueError):
                    parse_measurement(stdout, "S1")

        def test_equal_but_incorrect_checksums_rejected(self):
            rows = self.valid_rows()
            for row in rows:
                row["checksum"] = 0
            with self.assertRaises(ValueError):
                summarize(rows)

        def test_invalid_pair_and_nonfinite_ratio_rejected(self):
            rows = self.valid_rows()
            rows[0]["pair"] = False
            with self.assertRaises(ValueError):
                summarize(rows)
            rows = self.valid_rows()
            for row in rows:
                row["ns"] = 1e-300 if row["side"] == "innoflow" else 1e300
            with self.assertRaises(ValueError):
                summarize(rows)

        def test_incomplete_never_reports_metrics(self):
            with tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                report(output, {"status": "incomplete", "errors": ["missing S5"]}, {"S1": {"ns": 1}})
                result = json.loads((output / "summary.json").read_text())
                self.assertFalse(result["cohort_complete"])
                self.assertEqual(result["results"], {})

        def test_failed_and_timed_out_processes_keep_logs(self):
            for side_effect, return_value, status in (
                (subprocess.TimeoutExpired(["unused"], 1, output=b"partial", stderr=b"error"), None, "timeout"),
                (None, subprocess.CompletedProcess(["unused"], 2, b"partial", b"error"), "failed"),
            ):
                with self.subTest(status=status), tempfile.TemporaryDirectory() as temporary:
                    output = Path(temporary)
                    with patch("subprocess.run", side_effect=side_effect, return_value=return_value):
                        with self.assertRaises(RuntimeError):
                            run_command(["unused"], output, "case", output, {}, 1)
                    self.assertEqual((output / "logs/case.stdout").read_bytes(), b"partial")
                    self.assertEqual((output / "logs/case.stderr").read_bytes(), b"error")
                    self.assertEqual(json.loads((output / "logs/case.json").read_text())["status"], status)

        def test_resolved_pins_and_malformed_original_are_preserved(self):
            with tempfile.TemporaryDirectory() as temporary:
                repo, output = Path(temporary) / "repo", Path(temporary) / "evidence"
                for side, (relative, _) in PACKAGES.items():
                    source = repo / relative / "Package.resolved"
                    source.parent.mkdir(parents=True)
                    identity = "swift-composable-architecture" if side == "tca" else "swift-syntax"
                    write_json(source, {"version": 3, "pins": [{"identity": identity,
                               "state": {"version": "1.26.2" if side == "tca" else "604.0.0",
                                         "revision": "a" * 40}}]})
                captured = snapshot_resolutions(repo, output, "valid")
                self.assertTrue(all(entry["valid"] for entry in captured.values()))
                source = repo / PACKAGES["tca"][0] / "Package.resolved"
                source.write_text("{malformed original")
                captured = snapshot_resolutions(repo, output, "invalid")
                self.assertFalse(captured["tca"]["valid"])
                self.assertEqual((output / captured["tca"]["artifact"]).read_bytes(), source.read_bytes())
                source.unlink()
                self.assertFalse(snapshot_resolutions(repo, output, "missing")["tca"]["exists"])

        def test_swift_63_guard_leaves_incomplete_evidence_without_build(self):
            with tempfile.TemporaryDirectory() as temporary:
                repo, output = Path(temporary) / "repo", Path(temporary) / "evidence"
                repo.mkdir()
                (repo / "Package.swift").write_text("// swift-tools-version: 6.3\n")
                for side, (relative, _) in PACKAGES.items():
                    package = repo / relative
                    package.mkdir(parents=True)
                    (package / "Package.swift").write_text("// swift-tools-version: " + ("6.4" if side == "tca" else "6.3") + "\n")
                (repo / "Benchmarks/trend.py").write_text("# source fixture\n")
                outputs = {"repo-sha": "a" * 40, "repo-description": "fixture", "source-status": "",
                           "source-diff": "", "tracked-files": "", "swift-version": "Apple Swift version 6.3.3",
                           "xcode-version": "Xcode 26.6\nBuild version fixture", "hardware": "fixture",
                           "xcrun-swift-path": "/fixture/swift", "macos-sdk-path": "/fixture/SDK", "macos-sdk-version": "26.6"}

                def fake_command(command, output, name, repo, env, timeout):
                    return outputs[name]  # Any resolve/build/measurement command is an error.

                with patch(__name__ + ".run_command", side_effect=fake_command), \
                        patch("platform.system", return_value="Darwin"), \
                        patch("platform.machine", return_value="arm64"), \
                        patch("platform.platform", return_value="fixture-macOS"), \
                        patch("platform.processor", return_value="fixture-processor"):
                    self.assertEqual(capture(repo, output), 1)
                summary = json.loads((output / "summary.json").read_text())
                manifest = json.loads((output / "manifest.json").read_text())
                self.assertEqual(summary["status"], "incomplete")
                self.assertEqual(summary["results"], {})
                self.assertEqual(manifest["validated_processes"], 0)
                self.assertIn("tca needs Swift 6.4", " ".join(manifest["errors"]))
                self.assertEqual(set(manifest["resolutions_final"]), set(PACKAGES))

    return 0 if unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Controls)).wasSuccessful() else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, help="New directory outside the repository; preserve its raw evidence")
    parser.add_argument("--self-test", action="store_true", help="Run pure Python integrity controls without Swift")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.output is None:
        parser.error("--output is required")
    repo, output = args.repo.resolve(strict=True), args.output.resolve()
    if output == repo or repo in output.parents:
        parser.error("--output must be outside the source repository")
    if output.exists():
        parser.error("--output must be a fresh directory")
    return capture(repo, output)


if __name__ == "__main__":
    sys.exit(main())
