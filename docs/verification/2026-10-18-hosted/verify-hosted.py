"""Independently bind hosted job/artifact evidence to one exact pushed candidate."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as XML

parser = argparse.ArgumentParser()
parser.add_argument("phase")
parser.add_argument("sha")
parser.add_argument("--allow-failed-run", action="store_true")
args = parser.parse_args()
evidence = Path(__file__).resolve().parent
load = lambda path: json.loads(path.read_text())
run = load(evidence / f"run-{args.phase}.json")
jobs = load(evidence / f"jobs-{args.phase}.json")["jobs"]
artifacts = load(evidence / f"artifacts-{args.phase}.json")["artifacts"]
assert run["head_sha"] == args.sha
assert run["event"] == "push" and run["head_branch"] == "codex/multiplatform-flow"
assert run["head_repository"]["full_name"] == "InnoSquadCorp/InnoFlow"
assert run["path"] == ".github/workflows/ci-multiplatform.yml"
assert run["status"] == "completed"
expected_jobs = {"Multiplatform Contracts", "Kotlin Runtime and KSP Tests",
    "TypeScript Runtime and React Adapter Tests (20.19.0)", "TypeScript Runtime and React Adapter Tests (22)",
    "Android Lifecycle (API 23)", "Android Lifecycle (API 35)"}
assert {job["name"] for job in jobs} == expected_jobs and len(jobs) == 6
assert all(job["status"] == "completed" for job in jobs)
if not args.allow_failed_run:
    assert run["conclusion"] == "success"
    assert all(job["conclusion"] == "success" for job in jobs)
expected_artifacts = {"kotlin-unit-consumer-reports", "packed-consumers-node-20.19.0",
    "packed-consumers-node-22", "android-runtime-23", "android-runtime-35"}
assert {a["name"] for a in artifacts} == expected_artifacts and len(artifacts) == 5
archive_checks = []
for artifact in artifacts:
    assert artifact["workflow_run"]["head_sha"] == args.sha and not artifact["expired"]
    assert artifact["workflow_run"]["id"] == run["id"]
    assert artifact["workflow_run"]["head_branch"] == run["head_branch"]
    path = evidence / f'artifact-{artifact["id"]}.zip'
    assert path.stat().st_size == artifact["size_in_bytes"]
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    assert artifact["digest"] == "sha256:" + actual, artifact["name"]
    archive_checks.append(dict(name=artifact["name"], id=artifact["id"], bytes=path.stat().st_size,
                               sha256=actual, githubDigestVerified=True))
root = evidence / f"artifacts-{args.phase}"

def junit(paths, expected):
    paths = list(paths)
    assert paths, "Required JUnit reports are absent"
    tests = failures = errors = skipped = 0
    cases = []
    for path in paths:
        suite = XML.parse(path).getroot()
        actual = list(suite.iter("testcase"))
        assert int(suite.get("tests")) == len(actual), str(path)
        assert int(suite.get("failures", 0)) == 0 and int(suite.get("errors", 0)) == 0
        assert int(suite.get("skipped", 0)) == 0
        tests += len(actual)
        failures += len(list(suite.iter("failure")))
        errors += len(list(suite.iter("error")))
        skipped += len(list(suite.iter("skipped")))
        cases.extend(case.get("name") for case in actual)
    assert (tests, failures, errors, skipped) == (expected, 0, 0, 0), cases
    return dict(tests=tests, failures=failures, errors=errors, skipped=skipped, cases=cases)

kotlin_root = root / "kotlin-unit-consumer-reports"
kotlin = {}
for module, task, count in [("sample", "test", 26), ("inno-flow-android", "testDebugUnitTest", 1),
        ("android-sample", "testDebugUnitTest", 1), ("consumer-fixture", "test", 1),
        ("android-consumer-fixture", "testDebugUnitTest", 1)]:
    kotlin[module] = junit([path for path in kotlin_root.rglob("TEST-*.xml")
        if f"/{module}/build/test-results/{task}/" in path.as_posix()], count)

clean = lambda text: re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
typescript = {}
for node in ["20.19.0", "22"]:
    folder = root / f"packed-consumers-node-{node}"
    unit = clean((folder / "typescript-tests.log").read_text())
    assert re.search(r"Test Files\s+5 passed \(5\)", unit)
    assert re.search(r"Tests\s+28 passed \(28\)", unit)
    versions = []
    consumers = []
    for major, version in [(18, "18.2.0"), (19, "19.2.8")]:
        text = clean((folder / f"packed-react{major}.log").read_text())
        assert "Packed core, testing and React SSR: passed" in text
        match = re.search(r"Packed React " + re.escape(version) + r", Node ([\d.]+): typecheck, SSR, hydration, browser interactions and console passed", text)
        assert match, text
        versions.append(match[1])
        consumers.append(dict(react=version, node=match[1], result="PASS"))
    assert versions[0] == versions[1]
    assert versions[0] == "20.19.0" if node == "20.19.0" else versions[0].startswith("22.")
    control = (folder / "packed-value-controls.log").read_text()
    for expected in ["normal control passed", "wrong-ssr: rejected by the actual value oracle",
                     "wrong-browser: rejected by the actual value oracle", "normal + SSR/browser negative controls passed"]:
        assert expected in control
    assert len(list(folder.rglob("consumer.png"))) == 3
    assert len(list(folder.rglob("consumer-failed.png"))) == 1
    typescript[node] = dict(unitTests=28, unitFiles=5, consumers=consumers,
                           normalPackedControl=True, wrongSsrRejected=True, wrongBrowserRejected=True)

android = {}
package = "com.innosquad.innoflow.sample.android"
for api in [23, 35]:
    folder = root / f"android-runtime-{api}"
    compose = junit([p for p in folder.rglob("TEST-*.xml") if "/inno-flow-compose/" in p.as_posix()], 2)
    sample = junit([p for p in folder.rglob("TEST-*.xml") if "/android-sample/" in p.as_posix()], 1)
    fingerprints = list(folder.rglob("android-fingerprint.txt"))
    assert len(fingerprints) == 1 and fingerprints[0].read_text().strip()
    outputs = list(folder.rglob("result.json"))
    record = dict(compose=compose, recreation=sample, fingerprint=fingerprints[0].read_text().strip())
    if not outputs:
        assert args.allow_failed_run
        assert list(folder.rglob("failed.png"))
        record.update(restoration="FAIL", detail="No successful probe result JSON; failed screenshot retained")
    else:
        assert len(outputs) == 1
        result = load(outputs[0])
        assert all(re.fullmatch(r"[1-9][0-9]*", result[key]) for key in ["before", "after"])
        assert result["before"] != result["after"]
        assert result["initial"] == 0 and result["restored"] == 2
        assert result["method"] in ["am-kill", "same-uid-pid-kill"]
        probe = outputs[0].parent
        ui = XML.parse(probe / "latest-ui.xml").getroot()
        labels = [node.get("text", "") for node in ui.iter("node")]
        assert "Count: 2" in labels and not any("isn't responding" in label for label in labels)
        assert (probe / "restored.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
        stopped = (probe / "stopped-activities.txt").read_text()
        records = re.split(r"(?m)(?=^\s*\* Hist\s+#\d+: ActivityRecord\{)", stopped)
        target = [block for block in records if package + "/" in block.split("\n", 1)[0]]
        assert target
        assert all(re.search(r"\bstate=STOPPED\b", block) and
                   re.search(r"\b(?:mHaveState|haveState)=true\b", block) and
                   re.search(r"\b(?:mAppStopped|mStopped|stopped)=true\b", block) for block in target)
        crash = list(folder.rglob("android-crash.txt"))
        assert len(crash) == 1
        crash_text = crash[0].read_text()
        assert package not in crash_text
        record.update(restoration="PASS", result=result, visibleCount=2, crashBufferBytes=crash[0].stat().st_size,
                      fileFallbackUsed=(probe / "ui-file-status.txt").is_file(), probeDirectory=str(probe))
        if api == 23:
            identities = [json.loads(line) for line in (probe / "legacy-pids.jsonl").read_text().splitlines()]
            assert {result["before"], result["after"]}.issubset({entry["pid"] for entry in identities})
            assert all(entry["cmdline"].rstrip("\0") == package for entry in identities)
            record["legacyProcessIdentityReads"] = len(identities)
    android[str(api)] = record

logs = clean((evidence / f"{args.phase}-all-jobs.log").read_text())
for module in ["core", "testing", "ksp", "android", "compose"]:
    assert f":inno-flow-{module}:checkKotlinAbi" in logs
for case in ["positive: compiled", "private: expected diagnostic", "generic: expected diagnostic",
             "nested: expected diagnostic", "indirect: expected diagnostic", "abstract: expected diagnostic"]:
    assert f"[ksp-fixtures] {case}" in logs
assert "[android-api] Both real AAR API gates rejected changed baselines" in logs
assert "[multiplatform-ci] passing control and 10 negative evidence cases passed" in logs
for job in jobs:
    assert any(line.startswith(job["name"] + "\t") and args.sha in line for line in logs.splitlines()), \
        f"Missing exact checkout SHA in hosted job {job['name']}"
if args.phase in ["pid", "final"]:
    assert re.search(r"Ran 32 tests in", logs), "Restoration control tests did not all execute"
cache_evidence = sorted(set(re.findall(r"> Task ([^\r\n]+(?:FROM-CACHE|UP-TO-DATE))", logs)))
print(json.dumps(dict(phase=args.phase, sha=args.sha, runId=run["id"], attempt=run["run_attempt"],
    workflow=run["path"], branch=run["head_branch"], event=run["event"], conclusion=run["conclusion"],
    jobs=[dict(id=job["id"], name=job["name"], conclusion=job["conclusion"]) for job in jobs],
    artifactArchives=archive_checks, kotlin=kotlin, typescript=typescript, android=android,
    gradleReusedTaskEvidence=cache_evidence,
    rawLogsSha256=hashlib.sha256((evidence / f"{args.phase}-all-jobs.log").read_bytes()).hexdigest(),
    decision="PASS" if not args.allow_failed_run else "HISTORICAL RUN FAILURE PRESERVED"), indent=2))
