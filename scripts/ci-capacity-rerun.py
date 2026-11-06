#!/usr/bin/env python3
"""Rerun PR validation jobs that GitHub never assigned to a hosted runner.

Hosted macOS capacity shortages cancel queued jobs before any step runs. Such a
cancellation says nothing about the change, yet it fails CI Required and no
later event replaces it. Once per validation, the trusted coordinator reruns the
failed jobs of the latest validation of the current PR head, and only when every
other failure is an aggregate gate. The rerun's own jobs still decide every check.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time

# The exact annotation GitHub attaches when no hosted runner took a queued job.
CAPACITY = "The job was not acquired by Runner of type hosted even after multiple attempts"
# Only a first attempt is retried; capacity loss in a rerun waits for an operator.
ATTEMPT = 1
JOB = "capacity-rerun"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


METADATA = load("ci_metadata_policy", "ci-metadata-policy.py")
VERIFIER = load("verify_ci_metadata", "verify-ci-metadata.py")


def capacity_cancelled(api, p, job):
    """A queued job cancelled before any runner or step, with GitHub's capacity annotation."""
    if not (job.get("status") == "completed" and job.get("conclusion") == "cancelled" and
            job.get("runner_id") in {None, 0} and not job.get("runner_name") and job.get("steps") == []):
        return False
    url = job.get("check_run_url", "")
    prefix = f"https://api.github.com/repos/{p.REPOSITORY}/check-runs/"
    p.require(isinstance(url, str) and url.startswith(prefix) and re.fullmatch(r"[1-9][0-9]*", url[len(prefix):]),
              "missing validation job/check association")
    annotations = api.pages(p.route(f"check-runs/{url[len(prefix):]}/annotations"))
    return any(a.get("annotation_level") == "failure" and a.get("message") == CAPACITY for a in annotations)


def aggregate_failure(job):
    """An aggregate gate whose own aggregation step, and nothing else, failed."""
    name = job.get("name")
    steps = job.get("steps")
    if name not in METADATA.GATES or not isinstance(steps, list):
        return False
    normal = [s for s in steps if s.get("name") == METADATA.GATES[name]]
    return (job.get("status") == "completed" and job.get("conclusion") == "failure" and
            len(normal) == 1 and normal[0].get("conclusion") == "failure" and
            all(s is normal[0] or (s.get("status") == "completed" and s.get("conclusion") in {"success", "skipped"})
                for s in steps))


def targets(api, p, number):
    """The latest validation of this PR head, when only capacity cancelled it."""
    repo = api.get(p.route(""))
    p.require(repo.get("full_name") == p.REPOSITORY and type(repo.get("id")) is int, "wrong repository")
    pr = api.get(p.route(f"pulls/{number}"))
    # PR validation runs exist only for open same-repository PRs into main.
    if (pr.get("number") != number or pr.get("state") != "open" or
            pr.get("base", {}).get("ref") != "main" or pr.get("base", {}).get("repo", {}).get("id") != repo["id"] or
            pr.get("head", {}).get("repo", {}).get("id") != repo["id"]):
        return []
    head = pr["head"].get("sha") or ""
    p.require(bool(p.SHA.fullmatch(head)), "invalid PR head")
    workflow = api.get(p.route("actions/workflows/ci.yml"))
    p.require(workflow.get("path") == p.CI_PATH and workflow.get("state") == "active", "wrong/inactive CI workflow")
    runs = api.pages(p.route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
    p.require(all(type(r.get("id")) is int and r["id"] > 0 and type(r.get("run_number")) is int and r["run_number"] > 0
                  for r in runs), "invalid CI run ordering")
    ordinary = [r for r in runs if not str(r.get("display_title", "")).startswith(METADATA.PREFIX)]
    if not ordinary:
        return []
    # A newer validation supersedes the interrupted one; never revive it.
    listed = max(ordinary, key=lambda r: (r["run_number"], r["id"]))
    run = api.get(p.route(f"actions/runs/{listed['id']}"))
    bound = VERIFIER.TITLE.fullmatch(run.get("display_title", ""))
    if not (bound and int(bound[1]) == number and bound[2] == head and
            run.get("id") == listed["id"] and run.get("run_number") == listed["run_number"] and
            run.get("workflow_id") == workflow["id"] and run.get("path") == p.CI_PATH and
            run.get("event") == "pull_request" and run.get("head_sha") == head and
            run.get("repository", {}).get("id") == repo["id"] and
            run.get("head_repository", {}).get("id") == repo["id"] and
            run.get("status") == "completed" and run.get("conclusion") in {"failure", "cancelled"} and
            run.get("run_attempt") == ATTEMPT):
        return []
    jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{ATTEMPT}/jobs"), "jobs")
    cancelled = 0
    for job in jobs:
        if job.get("status") == "completed" and job.get("conclusion") in {"success", "skipped"}:
            continue
        if aggregate_failure(job):
            continue
        # Any real failure, or a cancellation with another cause, is the change's verdict.
        if not capacity_cancelled(api, p, job):
            return []
        cancelled += 1
    return [dict(pr=number, head=head, run=run["id"], attempt=ATTEMPT)] if cancelled else []


def request(api, p, target):
    """POST one exact failed-job rerun after re-deriving it; never retry an unknown outcome."""
    label = f"PR{target['pr']} run{target['run']} attempt{target['attempt']}"
    if target not in targets(api, p, target["pr"]):
        return label + ": no longer eligible"
    try:
        api.mutate("POST", p.route(f"actions/runs/{target['run']}/rerun-failed-jobs"), {})
    except Exception as error:
        # A lost reply is not permission to POST again; read the attempt back.
        print(f"{label}: rerun request raised {type(error).__name__}: {error}", file=sys.stderr)
    for index in range(4):
        live = api.get(p.route(f"actions/runs/{target['run']}"))
        if live.get("run_attempt", 0) > target["attempt"]:
            p.require(live.get("id") == target["run"] and live.get("run_attempt") == target["attempt"] + 1 and
                      live.get("head_sha") == target["head"], "rerun validation run identity changed")
            return label + ": capacity-cancelled jobs rerun; their results decide the checks"
        if index < 3:
            time.sleep(2)
    raise p.Rejected(label + ": rerun outcome unconfirmed; no automatic retry")


def main():
    p = load("merge_policy", "dependabot-merge-policy.py")
    try:
        p.trusted_context(os.environ)
        p.require(os.environ.get("GITHUB_JOB") == JOB and
                  os.environ.get("GITHUB_EVENT_NAME") in {"workflow_run", "schedule", "push", "workflow_dispatch"},
                  "capacity rerun requires its scoped background job")
        numbers = json.loads(os.environ["PR_NUMBERS"])
        p.require(isinstance(numbers, list) and all(type(n) is int and n > 0 for n in numbers) and
                  len(set(numbers)) == len(numbers), "invalid capacity rerun PR targets")
        api = p.GitHub()
    except (KeyError, TypeError, ValueError) as error:
        print("Capacity rerun rejected: " + str(error), file=sys.stderr)
        return 1
    status = 0
    for number in numbers:
        try:
            plans = targets(api, p, number)
            for target in plans:
                print(request(api, p, target))
            if not plans:
                print(f"PR{number}: no validation awaits a capacity rerun")
        except (KeyError, TypeError, ValueError, OSError) as error:
            # Unknown evidence leaves the failed checks in place; other PRs proceed.
            print(f"PR{number}: no capacity rerun: {error}", file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
