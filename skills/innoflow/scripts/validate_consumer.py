#!/usr/bin/env python3
"""Validate an isolated exact-release consumer and record reproducible evidence."""

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


def run_bounded_command(argv, output, timeout_seconds, error_output=subprocess.STDOUT):
    """Bound a command and reap it; kill its process group on timeout."""
    with subprocess.Popen(argv, stdout=output, stderr=error_output, start_new_session=True) as process:
        try:
            return process.wait(timeout=timeout_seconds), False
        except subprocess.TimeoutExpired:
            # Swift/git can spawn children. Killing just the leader leaves those
            # tools using the scratch directory after failure evidence is written.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # The complete group exited between wait and kill.
            return process.wait(), True


def positive_timeout(value):
    seconds = int(value)
    if seconds <= 0:
        raise argparse.ArgumentTypeError("command timeout must be a positive number of seconds")
    return seconds


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path, help="External SwiftPM cache and logs, retained after the run")
    parser.add_argument("--command-timeout", type=positive_timeout, default=3600,
                        help="Per-command timeout in seconds (default: 3600; increase for slow cold builds)")
    args = parser.parse_args()
    skill = Path(__file__).resolve().parents[1]
    scratch = (args.scratch_path or Path(tempfile.mkdtemp(prefix="innoflow-skill-"))).resolve()
    if scratch == skill or skill in scratch.parents:
        parser.error("Choose a scratch directory outside the installed skill")
    runs = scratch / "skill-runs"
    runs.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix="run-", dir=runs))
    evidence_file = run / "evidence.json"
    evidence = {"status": "running", "started_at": datetime.now(timezone.utc).isoformat(), "commands": []}

    def check(condition, message):
        if not condition:
            raise RuntimeError(message)

    def command(label, argv, structured_output=False):
        log = run / (label + ".log")
        entry = {"argv": [str(a) for a in argv], "log": str(log), "timeout_seconds": args.command_timeout}
        evidence["commands"].append(entry)
        with log.open("w") as output, ExitStack() as stack:
            error_output = subprocess.STDOUT
            if structured_output:
                error_log = run / (label + ".stderr.log")
                entry["stderr_log"] = str(error_log)
                error_output = stack.enter_context(error_log.open("w"))
            return_code, timed_out = run_bounded_command(entry["argv"], output, args.command_timeout, error_output)
            if timed_out:
                output.write(f"\n[consumer-validation] Command timed out after {args.command_timeout}s; process group killed.\n")
        entry["exit_code"] = return_code
        entry["timed_out"] = timed_out
        check(not timed_out, f"{label} timed out after {args.command_timeout}s; see {log}")
        check(return_code == 0, f"{label} failed ({return_code}); see {log}")
        return log.read_text(errors="replace").strip()

    def flatten(node):
        yield node
        for child in node.get("dependencies", []):
            yield from flatten(child)

    def pins(path):
        return {p["identity"]: p for p in json.loads(path.read_text())["pins"]}

    try:
        check(sys.platform == "darwin", "The fixture requires an Apple Swift development host")
        support = json.loads((skill / "references/support.json").read_text())
        evidence["supported_range"] = support["supported_range"]
        evidence["include_prereleases"] = support["include_prereleases"]
        evidence["validation_scope"] = "exact_baseline"
        expected = support["resolved_dependencies"]
        check(expected["innoflow"] == {k: support[k] for k in ("repository", "version", "revision")},
              "Library support and dependency record disagree")
        source = skill / "assets/consumer"
        original_pins = pins(source / "Package.resolved")
        check(set(original_pins) == set(expected), "Fixture lock and supported graph differ")
        for identity, baseline in expected.items():
            pin = original_pins[identity]
            check(pin["kind"] == "remoteSourceControl" and pin["location"] == baseline["repository"]
                  and pin["state"] == {k: baseline[k] for k in ("version", "revision")},
                  f"{identity} fixture pin differs from support record")
        evidence["swift"] = command("swift-version", ["swift", "--version"])
        evidence["xcode"] = command("xcode-version", ["xcodebuild", "-version"])
        evidence["source_sha256"] = {
            str(p.relative_to(source)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(source.rglob("*")) if p.is_file() and p.suffix in (".swift", ".resolved")
            and not {".build", ".swiftpm"}.intersection(p.relative_to(source).parts)
        }
        package = run / "consumer"
        shutil.copytree(source, package, ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))
        options = ["--package-path", package, "--scratch-path", scratch]
        command("resolve", ["swift", "package", *options, "resolve"])
        check(pins(package / "Package.resolved") == original_pins, "Resolution changed the fixture's exact pins")
        graph = json.loads(command("graph", ["swift", "package", *options, "show-dependencies", "--format", "json"], structured_output=True))
        nodes = {n["identity"]: n for n in flatten(graph)}
        # SwiftPM can omit SwiftSyntax from show-dependencies when using a prebuilt.
        # Verify its resolved checkout through workspace state instead of ignoring it.
        workspace = json.loads((scratch / "workspace-state.json").read_text())["object"]
        resolved = {d["packageRef"]["identity"]: d for d in workspace["dependencies"]}
        check(set(resolved) == set(expected), "Unexpected resolved workspace dependencies")
        prebuilts = {p["identity"]: p for p in workspace.get("prebuilts", [])}
        active = set(nodes) - {graph["identity"]}
        check(active <= set(expected) and set(expected) - active <= set(prebuilts),
              "Unexpected active dependency graph")
        evidence["dependencies"] = {}
        for identity, baseline in expected.items():
            dependency = resolved[identity]
            ref, state = dependency["packageRef"], dependency["state"]
            check(ref["kind"] == "remoteSourceControl" and ref["location"] == baseline["repository"]
                  and dependency.get("basedOn") is None and state["name"] == "sourceControlCheckout"
                  and state["checkoutState"] == {k: baseline[k] for k in ("version", "revision")},
                  f"{identity} workspace differs from release lock")
            checkout = (scratch / "checkouts" / dependency["subpath"]).resolve()
            check((scratch / "checkouts").resolve() in checkout.parents, f"{identity} uses a local override")
            if identity in nodes:
                node = nodes[identity]
                check(node["url"] == baseline["repository"] and node["version"] == baseline["version"]
                      and Path(node["path"]).resolve() == checkout,
                      f"{identity} active graph differs from release lock")
            if identity in prebuilts:
                prebuilt = prebuilts[identity]
                check(identity == "swift-syntax" and prebuilt["version"] == baseline["version"]
                      and Path(prebuilt["checkoutPath"]).resolve() == checkout
                      and (scratch / "prebuilts").resolve() in Path(prebuilt["path"]).resolve().parents,
                      f"{identity} has an unexpected prebuilt selection")
            revision = command(identity + "-head", ["git", "-C", checkout, "rev-parse", "HEAD"])
            check(revision == baseline["revision"], f"{identity} checkout revision differs from release lock")
            check(not command(identity + "-status", ["git", "-C", checkout, "status", "--porcelain", "--untracked-files=all"]),
                  f"{identity} checkout has modifications")
            evidence["dependencies"][identity] = {"version": baseline["version"], "revision": revision,
                                                   "clean": True, "prebuilt_selected": identity in prebuilts}
        output = command("swift-test", ["swift", "test", *options, "--no-parallel", "-Xswiftc",
                                         "-strict-concurrency=complete", "-Xswiftc", "-warnings-as-errors"])
        summaries = re.findall(r"Test run with (\d+) tests? in (\d+) suites? passed", output)
        check(bool(summaries), "Swift Testing passed summary not found; inspect the test log")
        evidence["swift_test_result"] = {"tests": sum(int(x) for x, _ in summaries),
                                         "suites": sum(int(x) for _, x in summaries), "failures": 0,
                                         "strict_concurrency": "complete", "warnings_as_errors": True}
        evidence["status"] = "passed"
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        evidence["status"] = "failed"
        evidence["error"] = str(error)
    finally:
        evidence["finished_at"] = datetime.now(timezone.utc).isoformat()
        evidence_file.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"status": evidence["status"], "evidence": str(evidence_file), "error": evidence.get("error")}, indent=2))
    return 0 if evidence["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
