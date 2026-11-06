#!/usr/bin/env python3
"""Ask Dependabot to rebase one stale update at a time.

A main change leaves open Dependabot PRs on an obsolete base: their merge proof
rejects until Dependabot rebases, and only that fresh PR lifecycle event replaces
an obsolete Ready. Dependabot obeys `@dependabot rebase` only from an account with
push access, never from the workflow token or a GitHub App, so an optional
repository secret holds that account's narrowly scoped token for the one comment.
Updates are serialized: while one update is current and not parked on a failed
validation, or a request is still pending, nothing else is asked. The comment
only starts Dependabot's own rebase; CI and the merge proof decide everything else.
"""
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import sys
import time

COMMAND = "@dependabot rebase"
# A person's equivalent request is pending work too.
REQUESTS = {COMMAND, "@dependabot recreate"}
SECRET = "DEPENDABOT_REBASE_TOKEN"
WORKFLOW_REF = "InnoSquadCorp/InnoFlow/.github/workflows/dependabot-rebase.yml@refs/heads/main"
# Dependabot normally answers within minutes. A request it ignored this long no
# longer holds the queue, and is never repeated for the same head.
PENDING = timedelta(hours=1)


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


def validation(api, p, workflow, number, head):
    """State of the latest real validation of this PR head: None, running, success or failure."""
    runs = api.pages(p.route(f"actions/workflows/ci.yml/runs?event=pull_request&head_sha={head}"), "workflow_runs")
    p.require(all(type(r.get("id")) is int and r["id"] > 0 and type(r.get("run_number")) is int and r["run_number"] > 0
                  for r in runs), "invalid CI run ordering")
    bound = []
    for run in runs:
        title = VERIFIER.TITLE.fullmatch(run.get("display_title", ""))
        if title and int(title[1]) == number and title[2] == head and run.get("workflow_id") == workflow["id"]:
            bound.append(run)
    if not bound:
        return None
    latest = max(bound, key=lambda r: (r["run_number"], r["id"]))
    if latest.get("status") != "completed":
        return "running"
    return "success" if latest.get("conclusion") == "success" else "failure"


def requested(api, p, number, since):
    """Latest rebase request on this PR made after its current head was committed."""
    stamp = since.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    times = []
    for comment in api.pages(p.route(f"issues/{number}/comments?since={stamp}")):
        if str(comment.get("body", "")).strip() in REQUESTS:
            created = timestamp(p, comment.get("created_at"))
            if created > since:
                times.append(created)
    return max(times, default=None)


def plan(api, p, now):
    """The oldest stale update to rebase, or None and why nothing is asked now."""
    repo = api.get(p.route(""))
    p.require(repo.get("full_name") == p.REPOSITORY and type(repo.get("id")) is int, "wrong repository")
    main = api.get(p.route("git/ref/heads/main"))["object"]["sha"]
    p.require(bool(p.SHA.fullmatch(main or "")), "invalid current main SHA")
    workflow = api.get(p.route("actions/workflows/ci.yml"))
    p.require(workflow.get("path") == p.CI_PATH and workflow.get("state") == "active", "wrong/inactive CI workflow")
    listed = api.pages(p.route("pulls?state=open&base=main"))
    p.require(all(type(pr.get("number")) is int and pr["number"] > 0 for pr in listed), "invalid open PR inventory")
    for number in sorted(pr["number"] for pr in listed if p.bot(pr)):
        pr = api.get(p.route(f"pulls/{number}"))
        if not (pr.get("number") == number and pr.get("state") == "open" and pr.get("draft") is False and p.bot(pr) and
                pr.get("base", {}).get("ref") == "main" and pr["base"].get("repo", {}).get("id") == repo["id"] and
                pr.get("head", {}).get("repo", {}).get("id") == repo["id"]):
            continue
        head = pr["head"].get("sha") or ""
        p.require(bool(p.SHA.fullmatch(head)), "invalid Dependabot head")
        # The merge proof's own freshness test: its base must still be main.
        if pr["base"].get("sha") == main:
            state = validation(api, p, workflow, number, head)
            if state != "failure":
                return None, f"PR{number} is the current update ({state or 'awaiting CI'}); others wait for it"
            continue  # A current update parked on failed validation never holds the others.
        committed = timestamp(p, api.get(p.route(f"git/commits/{head}")).get("committer", {}).get("date"))
        asked = requested(api, p, number, committed)
        if asked is not None:
            if now - asked < PENDING:
                return None, f"PR{number}: rebase requested at {asked.isoformat()}; waiting for Dependabot"
            continue  # Ignored for this head; never asked twice.
        return dict(pr=number, head=head, main=main, committed=committed), f"PR{number} is the oldest stale update"
    return None, "no stale Dependabot update awaits a rebase"


def request(api, writer, p, target, now):
    """Comment once on the re-derived target; a lost reply is read back, never re-sent."""
    label = f"PR{target['pr']} head {target['head'][:7]}"
    current, _ = plan(api, p, now)
    if current != target:
        return label + ": no longer the next stale update"
    try:
        writer.mutate("POST", p.route(f"issues/{target['pr']}/comments"), {"body": COMMAND})
    except Exception as error:
        print(f"{label}: rebase request raised {type(error).__name__}: {error}", file=sys.stderr)
    for index in range(4):
        if requested(api, p, target["pr"], target["committed"]) is not None:
            return label + ": rebase requested; Dependabot's new head starts validation"
        if index < 3:
            time.sleep(2)
    # Only a later scheduled run re-derives this; a duplicate request is harmless.
    raise p.Rejected(label + ": rebase request unconfirmed")


def main():
    p = load("merge_policy", "dependabot-merge-policy.py")
    try:
        p.require(os.environ.get("GITHUB_REPOSITORY") == p.REPOSITORY and
                  os.environ.get("GITHUB_REF") == "refs/heads/main" and
                  os.environ.get("GITHUB_WORKFLOW_REF") == WORKFLOW_REF and
                  os.environ.get("GITHUB_EVENT_NAME") in {"push", "workflow_run", "schedule", "workflow_dispatch"},
                  "rebase requests require the trusted default-main workflow")
        api = p.GitHub()
        now = datetime.now(timezone.utc)
        target, reason = plan(api, p, now)
        print(reason)
        if target is None:
            return 0
        token = os.environ.get(SECRET)
        if not token:
            print(f"::notice title=Dependabot rebase needed::{SECRET} is not configured; "
                  f"comment `{COMMAND}` on PR #{target['pr']} manually")
            return 0
        print(request(api, p.GitHub(token=token), p, target, now))
    except (KeyError, TypeError, ValueError, OSError) as error:
        print("Dependabot rebase rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
