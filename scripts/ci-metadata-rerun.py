#!/usr/bin/env python3
"""Rerun a metadata-only CI recheck that failed before its validation finished.

A metadata gate waits a bounded time for the exact real validation it mirrors.
Validation queued behind scarce runners can outlast that wait, leaving newer
failed required checks that no later event replaces. Once that same validation
succeeds, the trusted coordinator reruns the exact metadata run so its unchanged,
fail-closed verifier reads the finished evidence. Nothing here reports a verdict.
"""
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

# Each validation completion yields at most one automatic rerun: an attempt that
# started after validation finished already had the evidence and failed for
# another reason. The cap only bounds repeated validation reruns.
MAX_ATTEMPTS = 20
JOB = "metadata-rerun"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


METADATA = load("ci_metadata_policy", "ci-metadata-policy.py")
VERIFIER = load("verify_ci_metadata", "verify-ci-metadata.py")


def timestamp(p, value):
    p.require(isinstance(value, str), "missing native timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    p.require(parsed.tzinfo is not None, "native timestamp lacks a timezone")
    return parsed


def validation_finish(api, p, runs, workflow, number, head, merge):
    """Completion time of the latest real validation, or None while a rerun cannot pass."""
    ordinary = [r for r in runs if not str(r.get("display_title", "")).startswith(METADATA.PREFIX)]
    if not ordinary:
        return None, None
    listed = max(ordinary, key=lambda r: (r["run_number"], r["id"]))
    run = api.get(p.route(f"actions/runs/{listed['id']}"))
    bound = VERIFIER.TITLE.fullmatch(run.get("display_title", ""))
    # The verifier binds the latest validation to this PR head and test merge;
    # anything else still waits or rejects, so a rerun would only fail again.
    if not (bound and int(bound[1]) == number and bound[2] == head and bound[4] == merge and
            run.get("id") == listed["id"] and run.get("run_number") == listed["run_number"] and
            run.get("workflow_id") == workflow["id"] and run.get("path") == p.CI_PATH and
            run.get("event") == "pull_request" and run.get("head_sha") == head and
            run.get("status") == "completed" and run.get("conclusion") == "success"):
        return None, None
    p.require(type(run.get("run_attempt")) is int and run["run_attempt"] > 0, "invalid validation attempt")
    jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"), "jobs")
    required = [j for j in jobs if j.get("name") == "CI Required"]
    p.require(len(required) == 1 and required[0].get("status") == "completed" and
              required[0].get("conclusion") == "success", "validation lacks one successful CI Required job")
    return run, timestamp(p, required[0].get("completed_at"))


def targets(api, p, number):
    """Exact failed metadata runs of this PR that a rerun can now satisfy."""
    repo = api.get(p.route(""))
    p.require(repo.get("full_name") == p.REPOSITORY and type(repo.get("id")) is int, "wrong repository")
    pr = api.get(p.route(f"pulls/{number}"))
    # Metadata runs exist only for open same-repository PRs into main.
    if (pr.get("number") != number or pr.get("state") != "open" or
            pr.get("base", {}).get("ref") != "main" or pr.get("base", {}).get("repo", {}).get("id") != repo["id"] or
            pr.get("head", {}).get("repo", {}).get("id") != repo["id"]):
        return []
    head, merge = pr["head"].get("sha") or "", pr.get("merge_commit_sha") or ""
    p.require(bool(p.SHA.fullmatch(head)), "invalid PR head")
    if not p.SHA.fullmatch(merge):
        return []
    main = api.get(p.route("git/ref/heads/main"))["object"]["sha"]
    parents = api.get(p.route(f"git/commits/{merge}")).get("parents", [])
    if [x.get("sha") for x in parents] != [main, head]:
        # A stale test merge fails the verifier again; it needs a new head or base update.
        return []
    workflow = api.get(p.route("actions/workflows/ci.yml"))
    p.require(workflow.get("path") == p.CI_PATH and workflow.get("state") == "active", "wrong/inactive CI workflow")
    runs = api.pages(p.route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
    p.require(all(type(r.get("id")) is int and r["id"] > 0 and type(r.get("run_number")) is int and r["run_number"] > 0
                  for r in runs), "invalid CI run ordering")
    validation, finished = validation_finish(api, p, runs, workflow, number, head, merge)
    if validation is None:
        return []
    result = []
    for listed in runs:
        # Lower-numbered metadata runs are historical to the merge proof.
        if (not str(listed.get("display_title", "")).startswith(METADATA.PREFIX) or
                listed["run_number"] < validation["run_number"]):
            continue
        run = api.get(p.route(f"actions/runs/{listed['id']}"))
        binding = METADATA.TITLE.fullmatch(run.get("display_title", ""))
        if not (binding and int(binding[1]) == number and binding[2] == head and binding[5] == merge and
                run.get("id") == listed["id"] and run.get("workflow_id") == workflow["id"] and
                run.get("path") == p.CI_PATH and run.get("event") == "pull_request" and run.get("head_sha") == head and
                run.get("repository", {}).get("id") == repo["id"] and
                run.get("head_repository", {}).get("id") == repo["id"] and
                run.get("status") == "completed" and run.get("conclusion") == "failure" and
                type(run.get("run_attempt")) is int and 0 < run["run_attempt"] < MAX_ATTEMPTS and
                timestamp(p, run.get("run_started_at")) < finished):
            continue
        jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"), "jobs")
        if METADATA.failed_noop(jobs):
            result.append(dict(pr=number, head=head, run=run["id"], attempt=run["run_attempt"]))
    return result


def request(api, p, target):
    """POST one exact rerun after re-deriving it; never retry an unknown outcome."""
    label = f"PR{target['pr']} run{target['run']} attempt{target['attempt']}"
    if target not in targets(api, p, target["pr"]):
        return label + ": no longer eligible"
    try:
        api.mutate("POST", p.route(f"actions/runs/{target['run']}/rerun"), {})
    except Exception:
        # A lost reply is not permission to POST again; read the attempt back.
        pass
    for index in range(4):
        live = api.get(p.route(f"actions/runs/{target['run']}"))
        if live.get("run_attempt", 0) > target["attempt"]:
            p.require(live.get("id") == target["run"] and live.get("run_attempt") == target["attempt"] + 1 and
                      live.get("head_sha") == target["head"], "rerun metadata run identity changed")
            return label + ": rerun requested; its verifier decides the checks"
        if index < 3:
            time.sleep(2)
    raise p.Rejected(label + ": rerun outcome unconfirmed; no automatic retry")


def main():
    p = load("merge_policy", "dependabot-merge-policy.py")
    try:
        p.trusted_context(os.environ)
        p.require(os.environ.get("GITHUB_JOB") == JOB and
                  os.environ.get("GITHUB_EVENT_NAME") in {"workflow_run", "schedule", "push", "workflow_dispatch"},
                  "metadata rerun requires its scoped background job")
        numbers = json.loads(os.environ["PR_NUMBERS"])
        p.require(isinstance(numbers, list) and all(type(n) is int and n > 0 for n in numbers) and
                  len(set(numbers)) == len(numbers), "invalid metadata rerun PR targets")
        api = p.GitHub()
    except (KeyError, TypeError, ValueError) as error:
        print("Metadata rerun rejected: " + str(error), file=sys.stderr)
        return 1
    status = 0
    for number in numbers:
        try:
            plans = targets(api, p, number)
            for target in plans:
                print(request(api, p, target))
            if not plans:
                print(f"PR{number}: no failed metadata recheck awaits finished validation")
        except (KeyError, TypeError, ValueError, OSError) as error:
            # Unknown evidence leaves the failed checks in place; other PRs proceed.
            print(f"PR{number}: no metadata rerun: {error}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
