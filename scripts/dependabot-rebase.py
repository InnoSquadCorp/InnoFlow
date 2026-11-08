#!/usr/bin/env python3
"""Ask Dependabot to rebase one stale update at a time.

A main change leaves open Dependabot PRs on an obsolete base: their merge proof
rejects until Dependabot rebases, and only that fresh PR lifecycle event replaces
an obsolete Ready. Dependabot obeys `@dependabot rebase` only from an account with
push access, never from the workflow token or a GitHub App, so an optional
repository secret holds that account's narrowly scoped token for the one comment.
Updates are serialized: while one update is current and not parked on a failed
validation, or a request is still pending, nothing else is asked. Only Dependabot's
own +1 reaction proves it accepted a request, so a comment from an account it does
not obey only delays the queue until the acknowledgement window passes and never
ends it. The comment only starts Dependabot's own rebase; CI and the merge proof
decide everything else.
"""
from datetime import datetime, timedelta, timezone
import importlib.util
import os
from pathlib import Path
import sys
import time

COMMAND = "@dependabot rebase"
# A person's equivalent request is pending work too, once Dependabot accepts it.
REQUESTS = {COMMAND, "@dependabot recreate"}
SECRET = "DEPENDABOT_REBASE_TOKEN"
WORKFLOW_REF = "InnoSquadCorp/InnoFlow/.github/workflows/dependabot-rebase.yml@refs/heads/main"
# Dependabot reacts +1 to a command it accepts within seconds and ignores accounts
# without push access. An unacknowledged request holds the queue only this long.
ACKNOWLEDGE = timedelta(minutes=10)
# An accepted request that produced no new head this long is not repeated.
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


def identity(p, writer):
    """The commenting token's account: its own ignored request is never repeated."""
    viewer = writer.graphql("query { viewer { databaseId } }", {}).get("viewer")
    p.require(isinstance(viewer, dict) and type(viewer.get("databaseId")) is int and viewer["databaseId"] > 0,
              "unknown rebase request account")
    return viewer["databaseId"]


def acknowledged(api, p, comment):
    """Dependabot itself reacted +1, the mark it leaves on a command it accepts."""
    p.require(type(comment.get("id")) is int and comment["id"] > 0, "invalid rebase request comment")
    reactions = api.pages(p.route(f"issues/comments/{comment['id']}/reactions?content=%2B1"))
    return any(reaction.get("content") == "+1" and p.bot(reaction) for reaction in reactions)


def requests(api, p, number, since, now, own):
    """Requests made after the head was committed: accepted, unanswered, and our own ignored ones."""
    stamp = since.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    accepted, unanswered, ignored = [], [], []
    for comment in api.pages(p.route(f"issues/{number}/comments?since={stamp}")):
        if str(comment.get("body", "")).strip() not in REQUESTS:
            continue
        created = timestamp(p, comment.get("created_at"))
        if created <= since:
            continue
        if acknowledged(api, p, comment):
            accepted.append(created)
        elif now - created < ACKNOWLEDGE:
            unanswered.append(created)
        elif own is not None and comment.get("user", {}).get("id") == own:
            ignored.append(created)
        # Anyone else's unacknowledged request was never accepted and decides nothing.
    return accepted, unanswered, ignored


def plan(api, p, now, own):
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
        accepted, unanswered, ignored = requests(api, p, number, committed, now, own)
        recent = [moment for moment in accepted if now - moment < PENDING]
        if recent:
            return None, f"PR{number}: rebase accepted at {max(recent).isoformat()}; waiting for Dependabot's new head"
        if unanswered:
            return None, (f"PR{number}: rebase requested at {max(unanswered).isoformat()}; "
                          "waiting for Dependabot to acknowledge it")
        if accepted or ignored:
            continue  # Accepted without a new head, or our own request ignored: never asked twice.
        return dict(pr=number, head=head, main=main, committed=committed), f"PR{number} is the oldest stale update"
    return None, "no stale Dependabot update awaits a rebase"


def request(api, writer, p, target, now, own):
    """Comment once on the re-derived target; a lost reply is read back, never re-sent."""
    label = f"PR{target['pr']} head {target['head'][:7]}"
    current, _ = plan(api, p, now, own)
    if current != target:
        return label + ": no longer the next stale update"
    try:
        writer.mutate("POST", p.route(f"issues/{target['pr']}/comments"), {"body": COMMAND})
    except Exception as error:
        print(f"{label}: rebase request raised {type(error).__name__}: {error}", file=sys.stderr)
    unanswered = []
    for index in range(6):
        accepted, unanswered, _ = requests(api, p, target["pr"], target["committed"], now, own)
        if accepted:
            return label + ": Dependabot accepted the rebase request; its new head starts validation"
        if index < 5:
            time.sleep(5)
    if unanswered:
        # Later runs wait out the acknowledgement window, then never repeat it.
        raise p.Rejected(label + ": Dependabot has not acknowledged the rebase request; "
                         "the token's account may lack push access")
    # Nothing was posted, so a later run may ask again.
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
        token = os.environ.get(SECRET)
        writer = p.GitHub(token=token) if token else None
        own = identity(p, writer) if writer else None
        target, reason = plan(api, p, now, own)
        print(reason)
        if target is None:
            return 0
        if writer is None:
            print(f"::notice title=Dependabot rebase needed::{SECRET} is not configured; "
                  f"comment `{COMMAND}` on PR #{target['pr']} manually")
            return 0
        print(request(api, writer, p, target, now, own))
    except (KeyError, TypeError, ValueError, OSError) as error:
        print("Dependabot rebase rejected: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
