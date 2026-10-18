#!/usr/bin/env python3
"""Require successful Multiplatform CI for the exact main commit before publishing."""
import argparse
import json
import os
import re
import subprocess

def verify(document, repository, sha):
    runs = [run for run in document.get("workflow_runs", []) if
            run.get("head_sha") == sha and run.get("event") == "push" and
            run.get("head_branch") == "main" and
            run.get("head_repository", {}).get("full_name") == repository]
    if not runs:
        raise ValueError("No exact-SHA main Multiplatform CI run exists")
    latest = max(runs, key=lambda run: (run["id"], run.get("run_attempt", 1)))
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("The latest exact-SHA Multiplatform CI run has not succeeded")
    return latest["id"]

def selftest():
    base = dict(id=1, head_sha="a" * 40, event="push", head_branch="main",
                head_repository={"full_name": "InnoSquadCorp/InnoFlow"}, status="completed", conclusion="success")
    assert verify({"workflow_runs": [base]}, "InnoSquadCorp/InnoFlow", "a" * 40) == 1
    for patch in [dict(head_sha="b" * 40), dict(event="pull_request"), dict(head_branch="feature"),
                  dict(head_repository={"full_name": "foreign/fork"}), dict(status="in_progress"),
                  dict(conclusion="failure"), dict(conclusion="cancelled"), dict(conclusion="skipped")]:
        try:
            verify({"workflow_runs": [dict(base, **patch)]}, "InnoSquadCorp/InnoFlow", "a" * 40)
        except ValueError:
            pass
        else:
            raise AssertionError(f"Accepted invalid CI evidence: {patch}")
    for runs in [[], [base, dict(base, id=2, conclusion="failure")]]:
        try:
            verify({"workflow_runs": runs}, "InnoSquadCorp/InnoFlow", "a" * 40)
        except ValueError:
            pass
        else:
            raise AssertionError("Accepted absent or superseded CI evidence")
    print("[multiplatform-ci] passing control and 10 negative evidence cases passed")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        selftest()
    else:
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        sha = os.environ.get("GITHUB_SHA", "")
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise SystemExit("Exact repository and commit identity are required")
        endpoint = f"repos/{repository}/actions/workflows/ci-multiplatform.yml/runs?head_sha={sha}&event=push&branch=main&per_page=100"
        document = json.loads(subprocess.check_output(["gh", "api", endpoint], timeout=30))
        print(f"[multiplatform-ci] verified main run {verify(document, repository, sha)} for {sha}")
