#!/usr/bin/env python3
"""Bounded, same-runner paired measurement; never a replacement for release CI."""

import argparse
from collections import Counter
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time

BASELINE_SHA = "d581ecc9b4d82b19d7fdcb37ec989a63ef73ebd5"
BASE_BRANCH = "ci/flow-automation-standardization"
HEAD_BRANCH = "perf/shared-macro-consumer-fixtures"
BUDGET_SECONDS = 3300
SUPPORT_PATH = Path("Tests/InnoFlowTests/TestSupport.swift")
SUBPROCESS_PATH = Path("Tests/InnoFlowTests/SubprocessContractTests.swift")
COMPILE_PATH = Path("Tests/InnoFlowTests/CompileContractTests.swift")
METHODS = {
    "StaleScopeCrashContractTests": [
        "staleScopedStoreParentReleaseContract", "staleScopedCollectionContract",
        "staleSelectedStoreParentReleaseContract", "staleSelectedStoreDynamicMemberDebugContract",
        "inactiveSelectedStoreDynamicMemberDebugContract", "staleScopedStoreRequireAliveReleaseContract",
        "inactiveScopedStoreRequireAliveReleaseContract",
    ],
    "StaleScopeReleaseContractTests": [
        "staleScopedStoreReleaseNoCrash", "staleCollectionScopeReleaseNoCrash", "staleSelectedStoreReleaseNoCrash",
    ],
    "PhaseMapCrashContractTests": [
        "phaseMapDirectMutationCrashContract", "phaseMapUndeclaredTargetCrashContract",
        "phaseMapRestoresDirectMutationInReleaseLikeExecution",
        "phaseMapRejectsUndeclaredDynamicTargetsInReleaseLikeExecution",
    ],
    "ConditionalReducerReleaseContractTests": [
        "ifLetReleaseNoOpWhenStateAbsent", "ifCaseLetReleaseNoOpWhenCaseMismatches",
    ],
    "CompileContractTests": ["exportedMacroFeaturesWorkAcrossTargetBoundaries"],
}
EXPECTED_IDS = sorted(f"{suite}/{method}()" for suite, methods in METHODS.items() for method in methods)
# Select every test in all four subprocess suites, not a hand-picked subset.
FILTER = "|".join(list(METHODS)[:-1] + [
    r"CompileContractTests/exportedMacroFeaturesWorkAcrossTargetBoundaries\(\)",
])
SCENARIOS = {
    "INNOFLOW_STALE_SCOPE_SCENARIO": {
        "parent-released": False, "collection-entry-removed": False, "selected-parent-released": False,
        "selected-dynamic-member-parent-released": False, "selected-dynamic-member-source-inactive": False,
    },
    "INNOFLOW_STALE_SCOPE_RELEASE_SCENARIO": {
        "parent-released": True, "collection-entry-removed": True, "selected-parent-released": True,
        "scoped-require-alive-parent-released": False, "scoped-require-alive-collection-entry-removed": False,
    },
    "INNOFLOW_PHASEMAP_CRASH_SCENARIO": {"direct-mutation-crash": False, "undeclared-target-crash": False},
    "INNOFLOW_PHASEMAP_RELEASE_SCENARIO": {"direct-mutation-restore": True, "undeclared-target-noop": True},
    "INNOFLOW_CONDITIONAL_REDUCER_SCENARIO": {"iflet-absent-state": True, "ifcase-mismatched-state": True},
}
VARIANTS = [(), ("MANUAL_PATH",), ("FEATURE_A",), ("FEATURE_B",), ("FEATURE_C",),
            ("FEATURE_A", "FEATURE_B"), ("FEATURE_A", "FEATURE_C"),
            ("FEATURE_B", "FEATURE_C"), ("FEATURE_A", "FEATURE_B", "FEATURE_C")]

# Identical insertion in disposable checkouts only. It does not change arguments,
# environment passed to children, return values, assertions, or failure handling.
# Per-event files avoid shared mutable state. Missing observations fail validation.
ORIGINAL_WAIT = "    try process.run()\n    process.waitUntilExit()\n"
OBSERVED_WAIT = r'''    // BEGIN disposable contract-fixture measurement observer
    let measurementID = UUID().uuidString
    let measurementDirectory = ProcessInfo.processInfo.environment["INNOFLOW_BENCHMARK_EVENTS"]
    let measurementBuildIndex = arguments.firstIndex(of: "--build-path")
    let measurementBuildPath = measurementBuildIndex.flatMap {
      $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
    }
    let measurementBuildExisted = measurementBuildPath.map {
      FileManager.default.fileExists(atPath: $0)
    } ?? false
    let measurementPackageIndex = arguments.firstIndex(of: "--package-path")
    let measurementManifest = measurementPackageIndex.flatMap { index -> String? in
      guard index + 1 < arguments.count else { return nil }
      let manifest = URL(fileURLWithPath: arguments[index + 1])
        .appendingPathComponent("Package.swift")
      return try? String(contentsOf: manifest, encoding: .utf8)
    } ?? ""
    let measurementStarted = ProcessInfo.processInfo.systemUptime
    try process.run()
    process.waitUntilExit()
    let measurementElapsed = ProcessInfo.processInfo.systemUptime - measurementStarted
    if let measurementDirectory {
      let destination = URL(fileURLWithPath: measurementDirectory, isDirectory: true)
      let event: [String: Any] = [
        "schemaVersion": 1,
        "id": measurementID,
        "parentPID": ProcessInfo.processInfo.processIdentifier,
        "executable": executableURL.path,
        "arguments": arguments,
        "scenarioEnvironment": environment.filter { $0.key.hasSuffix("_SCENARIO") },
        "elapsedSeconds": measurementElapsed,
        "startedUptime": measurementStarted,
        "status": process.terminationStatus,
        "buildPathExisted": measurementBuildExisted,
        "consumerManifest": measurementManifest,
      ]
      // Best-effort observation must never replace the original test outcome.
      if let encoded = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
        try? encoded.write(to: destination.appendingPathComponent(measurementID + ".json"))
      }
      if let output = try? Data(contentsOf: stdoutURL) {
        try? output.write(to: destination.appendingPathComponent(measurementID + ".stdout.log"))
      }
      if let output = try? Data(contentsOf: stderrURL) {
        try? output.write(to: destination.appendingPathComponent(measurementID + ".stderr.log"))
      }
    }
    // END disposable contract-fixture measurement observer
'''


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def instrument(source):
    require(source.count(ORIGINAL_WAIT) == 1, "observer anchor must occur exactly once")
    require("BEGIN disposable contract-fixture" not in source, "observer already present")
    return source.replace(ORIGINAL_WAIT, OBSERVED_WAIT, 1)


def inventory(root):
    result = {}
    for relative in (SUBPROCESS_PATH, COMPILE_PATH):
        source = (root / relative).read_text()
        sections = re.split(r"\bstruct (\w+)\s*\{", source)
        for index in range(1, len(sections), 2):
            suite = sections[index]
            if suite not in METHODS:
                continue
            # Fixtures contain nested structs. The suite's tests precede them;
            # for the macro function inspect the complete enclosing source.
            body = source[source.index("struct " + suite):]
            if suite != "CompileContractTests":
                next_suite = re.search(r"\nstruct \w+ContractTests\s*\{", body[1:])
                if next_suite:
                    body = body[:next_suite.start() + 1]
            matches = re.findall(r'@Test\(\s*"([^"\n]+)"\s*\)\s+func (\w+)\(', body)
            selected = {name: title for title, name in matches if name in METHODS[suite]}
            require(set(selected) == set(METHODS[suite]), f"source inventory mismatch: {suite}")
            if suite != "CompileContractTests":
                require(len(matches) == len(METHODS[suite]), f"unexpected test in suite: {suite}")
            result.update({f"{suite}/{name}()": title for name, title in selected.items()})
    require(sorted(result) == EXPECTED_IDS, "source inventory must contain exactly 17 functions")
    require(len(set(result.values())) == 17, "test display names must be unique")
    return result


def validate_discovery(output):
    discovered = []
    for line in output.splitlines():
        match = re.fullmatch(r"(?:InnoFlowTests[./])?(\w+Tests/\w+\(\))", line.strip())
        if match and match.group(1).split("/", 1)[0] in METHODS:
            identifier = match.group(1)
            # `swift test list` may list other CompileContractTests, which are
            # outside this deliberately focused measurement.
            if identifier.split("/")[0] != "CompileContractTests" or identifier in EXPECTED_IDS:
                discovered.append(identifier)
    require(sorted(discovered) == EXPECTED_IDS, "discovery missing, duplicate, or unexpected selected test")
    return discovered


def validate_test_output(output, titles):
    count = len(titles)
    output = re.sub(r"\x1b\[[0-9;]*m", "", output)
    passed = re.findall(r'Test "([^"\n]+)" passed after [0-9.]+ seconds?\.', output)
    require(Counter(passed) == Counter(titles.values()), "test log missing, duplicate, or unexpected passing test")
    require(re.search(rf"Test run with {count} tests(?: in \d+ suites?)? passed after", output),
            f"missing complete {count}-test passing summary")
    require(not re.search(r'Test "[^"\n]+" (?:skipped|failed)\b', output), "failed or skipped selected test")
    return sorted(passed)


def argument_value(arguments, flag):
    require(arguments.count(flag) == 1, f"expected exactly one {flag}")
    index = arguments.index(flag)
    require(index + 1 < len(arguments), f"missing value for {flag}")
    return arguments[index + 1]


def macro_variant(event, revision):
    arguments = event["arguments"]
    global_defines = sorted(item[2:] for item in arguments if item.startswith("-D"))
    manifest = event["consumerManifest"]
    target_defines = sorted(set(re.findall(r'\.define\("([A-Z_]+)"\)', manifest)))
    require(not (global_defines and target_defines), "mixed global and fixture defines")
    if revision == "candidate":
        require(not global_defines, "candidate fixture defines must remain target-local")
        blocks = re.findall(r"swiftSettings:\s*\[([^\]]*)\]", manifest)
        require(len(blocks) == 2, "candidate manifest must have exactly two fixture swiftSettings blocks")
        per_target = [sorted(re.findall(r'\.define\("([A-Z_]+)"\)', block)) for block in blocks]
        require(per_target[0] == per_target[1] == target_defines,
                "candidate fixture targets must have identical, nonduplicate defines")
        require(all(not re.sub(r'\.define\("[A-Z_]+"\)|[,\s]', "", block) for block in blocks),
                "unexpected candidate fixture compiler setting")
    return tuple(global_defines or target_defines)


def validate_events(events, revision):
    require(events, "missing observer events")
    require(len({event["id"] for event in events}) == len(events), "duplicate observer event")
    require(len({event["parentPID"] for event in events}) == 1, "fixture cache must stay inside one test process")
    for event in events:
        require(event.get("schemaVersion") == 1 and event["elapsedSeconds"] >= 0, "invalid observer event")
    compilers = [event for event in events if event["arguments"][:1] == ["swiftc"]]
    builds = [event for event in events if event["arguments"][:2] == ["swift", "build"]]
    scenarios = [event for event in events if event["scenarioEnvironment"]]
    expected_compilers = 16 if revision == "baseline" else 5
    expected_roots = 10 if revision == "baseline" else 2
    require(len(compilers) == expected_compilers, f"expected {expected_compilers} direct harness compilations")
    expected_modes = {"-Onone": 7 if revision == "baseline" else 2, "-O": 9 if revision == "baseline" else 3}
    for mode, count in expected_modes.items():
        require(sum(mode in event["arguments"] for event in compilers) == count, f"wrong {mode} harness count")
    require(all(event["status"] == 0 for event in compilers), "failed direct harness compilation")
    require(len(builds) == 11, "expected all 11 macro consumer builds")
    require(all("--disable-experimental-prebuilts" in event["arguments"] and
                "-warnings-as-errors" in event["arguments"] for event in builds),
            "source fallback or warnings-as-errors missing")
    positive = [event for event in builds if event["status"] == 0]
    negative = [event for event in builds if event["status"] != 0]
    require(Counter(macro_variant(event, revision) for event in positive) == Counter(VARIANTS),
            "all nine positive macro variants must pass exactly once")
    require(len(negative) == 2, "both availability negative controls must fail")
    extension = [event for event in negative if "-application-extension" in event["arguments"]]
    require(len(extension) == 1, "global application-extension negative control missing")
    require(all(macro_variant(event, revision) == () for event in negative), "negative controls must use original no-flag fixture")
    roots = sorted(set(argument_value(event["arguments"], "--build-path") for event in builds))
    require(len(roots) == expected_roots, f"expected {expected_roots} macro scratch roots")
    require(sum(not event["buildPathExisted"] for event in builds) == expected_roots,
            "each macro scratch root must start cold once per test invocation")
    expected_scenarios = {(key, value): succeeds for key, values in SCENARIOS.items() for value, succeeds in values.items()}
    actual_scenarios = []
    for event in scenarios:
        require(len(event["scenarioEnvironment"]) == 1, "unexpected scenario environment")
        scenario = next(iter(event["scenarioEnvironment"].items()))
        require(scenario in expected_scenarios, f"unexpected scenario: {scenario}")
        require((event["status"] == 0) == expected_scenarios[scenario], f"wrong scenario outcome: {scenario}")
        actual_scenarios.append(scenario)
    require(Counter(actual_scenarios) == Counter(expected_scenarios.keys()), "all 16 subprocess scenarios must run once")
    macro_runtime = [event for event in events if Path(event["executable"]).name == "PublicMacroClient"]
    require(len(macro_runtime) == 1 and macro_runtime[0]["status"] == 0, "macro runtime control must pass")
    require(len(events) == len(compilers) + len(builds) + len(scenarios) + 1, "unexpected captured subprocess")
    return {
        "directSwiftcInvocations": len(compilers),
        "directSwiftcSeconds": sum(event["elapsedSeconds"] for event in compilers),
        "nestedSwiftBuildInvocations": len(builds),
        "nestedSwiftBuildSeconds": sum(event["elapsedSeconds"] for event in builds),
        "macroScratchRoots": roots,
        "macroPositiveBuilds": len(positive), "macroExpectedNegativeBuilds": len(negative),
        "scenarioExecutions": len(scenarios), "macroRuntimeExecutions": len(macro_runtime),
        "observerEvents": len(events), "testProcessPID": events[0]["parentPID"],
    }


def run_command(command, cwd, environment, directory, deadline):
    directory.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    result = {"command": command, "cwd": str(cwd), "status": "running", "elapsedSeconds": None}
    write_json(directory / "command.json", result)
    process = None
    try:
        remaining = deadline - time.monotonic()
        require(remaining > 0, "measurement's total time budget exhausted")
        with (directory / "stdout.log").open("wb") as stdout, (directory / "stderr.log").open("wb") as stderr:
            process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=stdout, stderr=stderr,
                                       start_new_session=True)
            try:
                result["returnCode"] = process.wait(timeout=remaining)
                result["status"] = "passed" if process.returncode == 0 else "failed"
            except subprocess.TimeoutExpired:
                result["status"] = "timed-out"
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                result["returnCode"] = process.returncode
    except Exception as error:
        result["status"] = "failed"
        result["error"] = str(error)
    finally:
        result["elapsedSeconds"] = time.monotonic() - started
        write_json(directory / "command.json", result)
    return result


def combined_output(directory):
    return "\n".join((directory / name).read_text(errors="replace") if (directory / name).exists() else ""
                     for name in ("stdout.log", "stderr.log"))


def measure_phase(root, revision, cache_state, titles, output, temporary, deadline,
                  command_prefix=None):
    command_prefix = command_prefix or ["/usr/bin/xcrun", "swift"]
    directory = output / f"{revision}-{cache_state}"
    events_directory = directory / "events"
    events_directory.mkdir(parents=True)
    tmp = temporary / f"{revision}-{cache_state}"
    tmp.mkdir(parents=True)
    environment = dict(os.environ, TMPDIR=str(tmp) + "/", LC_ALL="C", LANG="C", TERM="dumb",
                       NO_COLOR="1", INNOFLOW_BENCHMARK_EVENTS=str(events_directory))
    common = ["--package-path", str(root), "--jobs", "1", "--disable-experimental-prebuilts",
              "-Xswiftc", "-warnings-as-errors"]
    result = {"revision": revision, "rootCache": cache_state, "status": "running", "errors": []}
    write_json(directory / "result.json", result)
    try:
        build = run_command(command_prefix + ["build", "--build-tests"] + common, root, environment,
                            directory / "root-build", deadline)
        result["rootBuild"] = build
        require(build["status"] == "passed", "root build failed; test execution not claimed")
        # List is separate overhead. --skip-build prevents hidden root compilation.
        listing = run_command(command_prefix + ["test", "list", "--skip-build"] + common, root, environment,
                              directory / "discovery", deadline)
        result["discovery"] = listing
        require(listing["status"] == "passed", "test discovery failed")
        result["discoveredTestIdentifiers"] = validate_discovery(combined_output(directory / "discovery"))
        tests = run_command(command_prefix + ["test", "--skip-build", "--no-parallel", "--filter", FILTER] + common,
                            root, environment, directory / "tests", deadline)
        result["testExecution"] = tests
        # Read and preserve observations even when tests fail or time out.
        events = [json.loads(path.read_text()) for path in sorted(events_directory.glob("*.json"))]
        events.sort(key=lambda event: event["startedUptime"])
        write_json(directory / "events.json", events)
        result["observedEventCount"] = len(events)
        require(tests["status"] == "passed", "selected test execution failed")
        result["passedTestTitles"] = validate_test_output(combined_output(directory / "tests"), titles)
        result["subprocesses"] = validate_events(events, revision)
        for event in events:
            for suffix in (".stdout.log", ".stderr.log"):
                require((events_directory / (event["id"] + suffix)).is_file(), "missing raw subprocess output")
        for event in events:
            if event["arguments"][:2] == ["swift", "build"] and event["status"] != 0:
                diagnostics = "\n".join((events_directory / (event["id"] + suffix)).read_text(errors="replace")
                                        for suffix in (".stdout.log", ".stderr.log"))
                require("unavailable" in diagnostics.lower(), "negative control missing unavailable diagnostic")
        result["buildPlusTestSeconds"] = build["elapsedSeconds"] + tests["elapsedSeconds"]
        result["includingDiscoverySeconds"] = result["buildPlusTestSeconds"] + listing["elapsedSeconds"]
        result["status"] = "passed"
    except Exception as error:
        result["status"] = "failed"
        result["errors"].append(str(error))
    write_json(directory / "result.json", result)
    return result



def validate_cache_tests(root, output, temporary, deadline):
    """Additional candidate correctness validation, outside paired timing totals."""
    source = (root / "Tests/InnoFlowTests/CompiledHarnessCacheTests.swift").read_text()
    titles = {name: title for title, name in re.findall(r'@Test\(\s*"([^"\n]+)"\s*\)\s+func (\w+)\(', source)}
    require(set(titles) == {"reusesFiveVariants", "separatesCompilerInputs", "retriesFailure", "rejectsMissingOutput",
                            "rebuildsMissingExecutable", "coalescesConcurrentRequests", "isolatesInstancesAndCleansUp",
                            "preservesProcessIsolation"}, "cache validation inventory must contain all eight tests")
    directory = output / "candidate-cache-validation"
    temporary.mkdir(parents=True)
    environment = dict(os.environ, TMPDIR=str(temporary) + "/", LC_ALL="C", LANG="C", TERM="dumb", NO_COLOR="1")
    environment.pop("INNOFLOW_BENCHMARK_EVENTS", None)
    result = run_command(["/usr/bin/xcrun", "swift", "test", "--package-path", str(root), "--skip-build",
                          "--jobs", "1", "--no-parallel", "--filter", "CompiledHarnessCacheTests",
                          "--disable-experimental-prebuilts", "-Xswiftc", "-warnings-as-errors"],
                         root, environment, directory, deadline)
    result["includedInPairedTiming"] = False
    if result["status"] == "passed":
        try:
            result["passedTestTitles"] = validate_test_output(combined_output(directory), titles)
        except ValueError as error:
            result["status"] = "failed"
            result["error"] = str(error)
    write_json(directory / "result.json", result)
    return result


def git(root, *arguments, deadline):
    remaining = deadline - time.monotonic()
    require(remaining > 0, "measurement's total time budget exhausted")
    return subprocess.check_output(["git", "-C", str(root), *arguments], text=True, timeout=remaining).strip()


def verify_event(event, candidate_sha):
    pr = event["pull_request"]
    require(pr["base"]["ref"] == BASE_BRANCH, "unexpected pull request base branch")
    require(pr["head"]["ref"] == HEAD_BRANCH, "unexpected pull request head branch")
    require(pr["head"]["sha"] == candidate_sha, "candidate is not exact pull request head")
    require(pr["head"]["repo"]["full_name"] == pr["base"]["repo"]["full_name"], "fork not authorized")
    return {"number": event["number"], "headSHA": candidate_sha, "eventBaseSHA": pr["base"]["sha"],
            "repository": pr["base"]["repo"]["full_name"], "baseBranch": BASE_BRANCH, "headBranch": HEAD_BRANCH}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--temporary", required=True, type=Path)
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    deadline = started + BUDGET_SECONDS
    summary = {"schemaVersion": 1, "status": "running", "baselineSHA": BASELINE_SHA,
               "candidateSHA": arguments.candidate_sha, "budgetSeconds": BUDGET_SECONDS,
               "measurementOrder": ["baseline-clean", "candidate-clean", "candidate-warm", "baseline-warm"],
               "phases": [], "errors": [], "expectedTestIdentifiers": EXPECTED_IDS,
               "observerSHA256": hashlib.sha256(OBSERVED_WAIT.encode()).hexdigest(),
               "timingDefinition": "buildPlusTestSeconds = root build + test execution; nested compiler times are included in tests, never added again",
               "limitations": ["one ABBA pair, not statistical performance or release evidence",
                               "clean describes checkout .build only; OS, network and SwiftPM download caches are not flushed",
                               "each test invocation has a fresh TMPDIR and process-scoped fixture cache",
                               "counts cover captured direct swiftc and nested swift build commands, not Swift frontend children"]}
    write_json(output / "summary.json", summary)
    try:
        require(platform.system() == "Darwin", "real measurement requires macOS")
        require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GITHUB_EVENT_NAME") == "pull_request",
                "real measurement runs only in the bounded GitHub pull_request job")
        require(os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted", "GitHub-hosted runner required")
        require(re.fullmatch(r"[0-9a-f]{40}", arguments.candidate_sha), "candidate SHA must be immutable")
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        summary["pullRequest"] = verify_event(event, arguments.candidate_sha)
        summary["run"] = {key: os.environ.get(key) for key in
                          ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion")}
        roots = {"baseline": arguments.baseline.resolve(), "candidate": arguments.candidate.resolve()}
        require(roots["baseline"] != roots["candidate"], "separate revision checkouts required")
        for revision, root in roots.items():
            expected_sha = BASELINE_SHA if revision == "baseline" else arguments.candidate_sha
            require(git(root, "rev-parse", "HEAD", deadline=deadline) == expected_sha, f"wrong {revision} checkout")
            require(not git(root, "status", "--porcelain", deadline=deadline), f"dirty {revision} checkout")
            require(not (root / ".build").exists(), f"{revision} clean build already exists")
        require((roots["baseline"] / SUBPROCESS_PATH).read_bytes() == (roots["candidate"] / SUBPROCESS_PATH).read_bytes(),
                "subprocess scenario assertions changed")
        titles = {revision: inventory(root) for revision, root in roots.items()}
        require(titles["baseline"] == titles["candidate"], "test inventory or titles changed")
        summary["testTitles"] = titles["baseline"]
        for name, command in (("xcode", ["/usr/bin/xcodebuild", "-version"]),
                              ("swift", ["/usr/bin/xcrun", "swift", "--version"])):
            receipt = run_command(command, roots["candidate"], os.environ, output / "toolchain" / name, deadline)
            require(receipt["status"] == "passed", f"{name} lookup failed")
            summary[name] = combined_output(output / "toolchain" / name).strip()
        require(re.search(r"^Xcode 26\.6$", summary["xcode"], re.M), "exact Xcode 26.6 required")
        require(re.search(r"Swift version 6\.3(?:\.|\s)", summary["swift"]), "Swift 6.3 required")
        summary["sourceHashes"] = {}
        for revision, root in roots.items():
            original = (root / SUPPORT_PATH).read_text()
            patched = instrument(original)
            summary["sourceHashes"][revision] = {str(path): hashlib.sha256((root / path).read_bytes()).hexdigest()
                                                 for path in (SUPPORT_PATH, SUBPROCESS_PATH, COMPILE_PATH)}
            (output / f"{revision}-observer.diff").write_text("".join(difflib.unified_diff(
                original.splitlines(True), patched.splitlines(True), fromfile=str(SUPPORT_PATH), tofile=str(SUPPORT_PATH))))
            summary["sourceHashes"][revision]["instrumentedTestSupportSHA256"] = hashlib.sha256(patched.encode()).hexdigest()
            (root / SUPPORT_PATH).write_text(patched)
        for revision, cache_state in (("baseline", "clean"), ("candidate", "clean"),
                                      ("candidate", "warm"), ("baseline", "warm")):
            result = measure_phase(roots[revision], revision, cache_state, titles[revision], output,
                                   arguments.temporary.resolve(), deadline)
            summary["phases"].append(result)
            write_json(output / "summary.json", summary)
        candidate_built = any(phase["revision"] == "candidate" and phase.get("rootBuild", {}).get("status") == "passed"
                              for phase in summary["phases"])
        if candidate_built:
            summary["candidateCacheValidation"] = validate_cache_tests(
                roots["candidate"], output, arguments.temporary.resolve() / "candidate-cache-validation", deadline)
        else:
            summary["candidateCacheValidation"] = {"status": "blocked", "error": "candidate root build failed"}
        require(all(phase["status"] == "passed" for phase in summary["phases"]), "one or more measurement phases failed")
        require(summary["candidateCacheValidation"]["status"] == "passed", "candidate cache correctness validation failed")
        summary["comparison"] = {}
        for cache_state in ("clean", "warm"):
            phases = {phase["revision"]: phase for phase in summary["phases"] if phase["rootCache"] == cache_state}
            baseline, candidate = phases["baseline"], phases["candidate"]
            require(not set(baseline["subprocesses"]["macroScratchRoots"]) & set(candidate["subprocesses"]["macroScratchRoots"]),
                    "revision fixture paths overlapped")
            summary["comparison"][cache_state] = {
                metric: {"baselineSeconds": baseline[metric], "candidateSeconds": candidate[metric],
                         "candidateOverBaseline": candidate[metric] / baseline[metric]}
                for metric in ("buildPlusTestSeconds", "includingDiscoverySeconds")
            }
        for revision in roots:
            phase_roots = [set(phase["subprocesses"]["macroScratchRoots"]) for phase in summary["phases"]
                           if phase["revision"] == revision]
            require(not phase_roots[0] & phase_roots[1], "warm root reused a prior invocation's temporary consumer root")
        summary["status"] = "passed"
    except Exception as error:
        summary["status"] = "failed"
        summary["errors"].append(str(error))
    finally:
        summary["runnerElapsedSeconds"] = time.monotonic() - started
        write_json(output / "summary.json", summary)
        print(json.dumps({"status": summary["status"], "errors": summary["errors"], "summary": str(output / "summary.json")}))
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
