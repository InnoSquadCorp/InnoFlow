#!/usr/bin/env python3
"""Plan InnoFlow CI from exact Git changes and reject incomplete results (stdlib only)."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

JOBS = (
    "policy", "docs-required", "documentation", "coverage", "lint", "tests", "release-tests",
    "api-compatibility", "thread-sanitizer", "sample-tests", "package-builds",
    "focused-runtime-tests", "principle-gates", "sample-package-builds",
    "sample-build", "address-sanitizer", "sample-ui-tests", "swift-syntax-compatibility",
)
SHA = re.compile(r"[0-9a-f]{40}")
PR_ACTIONS = {"opened", "synchronize", "reopened", "labeled", "unlabeled", "edited"}
# These are the original execution dependencies, not a replacement test matrix.
DEPENDENCIES = {
    "tests": {"lint"}, "release-tests": {"lint"}, "api-compatibility": {"lint"},
    "thread-sanitizer": {"lint"}, "sample-tests": {"lint"},
    "package-builds": {"lint"}, "focused-runtime-tests": {"lint"},
    "principle-gates": {"lint", "coverage"}, "sample-package-builds": {"sample-tests"},
    "sample-build": {"lint"}, "address-sanitizer": {"lint"},
    "sample-ui-tests": {"sample-build"}, "swift-syntax-compatibility": {"lint"},
}
WORKFLOW_IMPACT = {
    "ci.yml": set(JOBS),
    "coverage.yml": {"coverage"},
    "docs.yml": {"lint", "documentation"},
    "docs-publish.yml": {"lint", "documentation"},
    "asan.yml": {"address-sanitizer"},
    "cd.yml": set(JOBS),
    "release-evidence.yml": set(JOBS),
    "release-preflight.yml": set(JOBS),
    "dependabot-auto-merge.yml": set(),
    "dependabot-review-notice.yml": set(),
    "dependabot-ready.yml": set(),
}
DOC_TOOLS = {
    "Tools/generate-docc.sh", "scripts/check-doc-contract.sh",
    "scripts/check-doc-copyable-examples.rb", "scripts/check-doc-parity.sh",
    "scripts/check-doc-swift-syntax.rb", "scripts/doc-example-contexts.rb",
    "scripts/inventory-doc-swift-blocks.rb", "scripts/inventory-doc-swift-blocks-selftest.rb",
    "scripts/report-doc-fence-review.rb", "scripts/report-doc-fence-review-selftest.rb",
}
DOC_CONTRACTS = {
    "docs/contracts/doc-swift-syntax-exceptions.json",
    "docs/contracts/doc-swift-fence-review.tsv", "docs/contracts/doc-parity.json",
}


def reuse_policy():
    spec = importlib.util.spec_from_file_location("main_ci_reuse_policy", Path(__file__).with_name("main-ci-reuse-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def reused_jobs(plan, proof):
    reuse = reuse_policy()
    reuse.validate_proof(proof)
    if not proof:
        return set()
    if plan["lane"] != "full" or plan["jobs"] != {job: True for job in JOBS}:
        raise ValueError("reuse must preserve every full logical requirement")
    return set(reuse.REUSED_JOBS)


def path_impact(path):
    if not isinstance(path, str) or not path or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise ValueError("invalid changed path")
    if path.startswith("/") or any(p in ("..", ".", "") for p in path.split("/")) or "\\" in path:
        raise ValueError("changed path must be a repository-relative POSIX path")
    # A source-tree README/DocC file can change generated APIs or executable
    # examples. Deliberately check source prefixes before documentation suffixes.
    if path.startswith(("Sources/", "Tests/", "Examples/", "Plugins/", "Repro/")):
        return set(JOBS), "source/macro/test/example (all InnoFlow gates)"
    if path in ("Package.swift", "Package.resolved", ".swift-format") or path.startswith(".github/actions/"):
        return set(JOBS), "shared package/toolchain"
    if path.startswith(".github/workflows/"):
        name = path.removeprefix(".github/workflows/")
        if name in WORKFLOW_IMPACT:
            return set(WORKFLOW_IMPACT[name]), "workflow:" + name
        return set(JOBS), "unknown workflow (full fallback)"
    if path == ".spi.yml" or path in DOC_TOOLS or path in DOC_CONTRACTS:
        return {"lint", "documentation"}, "documentation tooling/contract"
    # Other contracts include coverage floors, runtime inventory and release
    # policy; never mistake those for prose merely because they live in docs/.
    if path.startswith("docs/contracts/"):
        return set(JOBS), "shared verification contract"
    if path.startswith(".github/ISSUE_TEMPLATE/") or path in (
            ".github/dependabot.yml", ".github/PULL_REQUEST_TEMPLATE.md", ".github/FUNDING.yml", "LICENSE"):
        return set(), "public operations"
    if path.endswith(".md") or path.startswith("docs/") and path.endswith((".png", ".jpg", ".svg")):
        return {"lint", "documentation"}, "documentation"
    return set(JOBS), "unknown/shared path (full fallback)"


def with_dependencies(selected):
    selected = set(selected) | {"policy", "docs-required"}
    while True:
        expanded = selected | set().union(*(DEPENDENCIES.get(job, set()) for job in selected))
        if expanded == selected:
            return selected
        selected = expanded


def changed_paths(root, base, head):
    if not SHA.fullmatch(base or "") or not SHA.fullmatch(head or ""):
        raise ValueError("diff anchors must be exact lowercase commit SHAs")
    raw = subprocess.check_output([
        "git", "-C", str(root), "diff", "--name-status", "-z", "--find-renames", base + "..." + head,
    ])
    if not raw:
        return []
    tokens = raw.decode("utf-8", errors="strict").split("\x00")
    if tokens.pop() != "":
        raise ValueError("truncated Git changed-file stream")
    paths = []
    index = 0
    while index < len(tokens):
        status = tokens[index]
        index += 1
        if not re.fullmatch(r"(?:[ADMT]|[RC][0-9]{1,3})", status):
            raise ValueError("unknown or unresolved Git file status")
        if status[0] in "RC" and int(status[1:]) > 100:
            raise ValueError("invalid Git similarity score")
        count = 2 if status[0] in "RC" else 1
        if len(tokens) - index < count:
            raise ValueError("missing changed-file path")
        # Both sides of a rename/copy and deleted files remain relevant even
        # when the old name no longer exists in the checkout.
        for path in tokens[index:index + count]:
            path_impact(path)
            paths.append(path)
        index += count
    return paths


def make_plan(event_name, event, paths):
    if not isinstance(event, dict) or not isinstance(paths, list):
        raise ValueError("event and changed paths have invalid types")
    lane = "full"
    requested = []
    if event_name == "pull_request":
        pr = event.get("pull_request")
        if event.get("action") not in PR_ACTIONS or not isinstance(pr, dict):
            raise ValueError("unsupported PR event")
        labels = pr.get("labels")
        user = pr.get("user")
        if not isinstance(labels, list) or any(not isinstance(x, dict) or not isinstance(x.get("name"), str) for x in labels):
            raise ValueError("missing or malformed PR labels")
        if not isinstance(user, dict) or not isinstance(user.get("login"), str) or not user["login"]:
            raise ValueError("missing or malformed PR author")
        if event["action"] == "edited" and not event.get("changes", {}).get("base"):
            raise ValueError("metadata-only edit must not create a validation plan")
        names = {label["name"].lower() for label in labels}
        lane = "release-validation" if user["login"] == "dependabot[bot]" or "release-validation" in names else "fast"
        if "run-asan" in names:
            requested = ["address-sanitizer"]
    elif event_name == "push":
        repository = event.get("repository", {})
        if not isinstance(repository, dict):
            raise ValueError("malformed repository metadata")
        default = repository.get("default_branch", "main")
        if not isinstance(default, str) or not default:
            raise ValueError("malformed default branch")
        if event.get("ref") not in {"refs/heads/main", "refs/heads/develop", "refs/heads/" + default}:
            raise ValueError("CI push must target main/develop/default branch")
    elif event_name == "merge_group":
        if event.get("action") != "checks_requested":
            raise ValueError("unsupported merge queue event")
    elif event_name != "workflow_dispatch":
        raise ValueError("unsupported CI event")
    selected = set(requested)
    changes = []
    for path in paths:
        impact, reason = path_impact(path)
        selected.update(impact)
        changes.append({"path": path, "reason": reason})
    selected = with_dependencies(selected)
    # Empty or unavailable evidence cannot justify skipping a validation gate.
    if lane != "fast" or not paths:
        selected = set(JOBS)
    return {"schema": 1, "lane": lane, "requested": requested,
            "jobs": {job: job in selected for job in JOBS}, "changes": changes}


def validate_plan(plan):
    if not isinstance(plan, dict) or set(plan) != {"schema", "lane", "requested", "jobs", "changes"}:
        raise ValueError("missing or unknown plan fields")
    if type(plan["schema"]) is not int or plan["schema"] != 1 or plan["lane"] not in ("fast", "full", "release-validation"):
        raise ValueError("unsupported plan schema/lane")
    if not isinstance(plan["jobs"], dict) or set(plan["jobs"]) != set(JOBS) or any(type(v) is not bool for v in plan["jobs"].values()):
        raise ValueError("plan must declare every job with a boolean")
    if plan["requested"] not in ([], ["address-sanitizer"]):
        raise ValueError("invalid explicitly requested checks")
    if not isinstance(plan["changes"], list):
        raise ValueError("invalid change evidence")
    selected = set(plan["requested"])
    for change in plan["changes"]:
        if not isinstance(change, dict) or set(change) != {"path", "reason"}:
            raise ValueError("invalid change record")
        impact, reason = path_impact(change["path"])
        if change["reason"] != reason:
            raise ValueError("invalid changed-path requirement")
        selected.update(impact)
    expected = with_dependencies(selected)
    if plan["lane"] != "fast" or not plan["changes"]:
        expected = set(JOBS)
    if plan["jobs"] != {job: job in expected for job in JOBS}:
        raise ValueError("plan does not match required changed-path and dependency selection")


def evaluate(plan, needs, proof=None):
    validate_plan(plan)
    reused = reused_jobs(plan, proof or {})
    if not isinstance(needs, dict) or set(needs) != set(JOBS) | {"ci-plan"}:
        raise ValueError("missing or unexpected CI result")
    for job, selected in {"ci-plan": True, **plan["jobs"]}.items():
        result = needs[job].get("result") if isinstance(needs[job], dict) else None
        expected = "success" if selected and job not in reused else "skipped"
        if result != expected:
            raise ValueError(f"{job}: expected {expected}, got {result!r}")


def evaluate_documentation(plan, needs):
    validate_plan(plan)
    if not isinstance(needs, dict) or set(needs) != {"ci-plan", "documentation"}:
        raise ValueError("missing or unexpected documentation result")
    for job, active in {"ci-plan": True, "documentation": plan["jobs"]["documentation"]}.items():
        result = needs[job].get("result") if isinstance(needs[job], dict) else None
        expected = "success" if active else "skipped"
        if result != expected:
            raise ValueError(f"{job}: expected {expected}, got {result!r}")


def load_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan_cmd = sub.add_parser("plan")
    plan_cmd.add_argument("--event", required=True, type=Path)
    plan_cmd.add_argument("--root", type=Path, default=Path("."))
    plan_cmd.add_argument("--output", type=Path, required=True)
    plan_cmd.add_argument("--reuse-proof-json", default=os.environ.get("CI_REUSE", "{}"))
    for name in ("evaluate", "evaluate-documentation"):
        evaluate_cmd = sub.add_parser(name)
        evaluate_cmd.add_argument("--plan-json", default=os.environ.get("CI_PLAN", ""))
        evaluate_cmd.add_argument("--needs-json", default=os.environ.get("CI_NEEDS", ""))
        evaluate_cmd.add_argument("--reuse-proof-json", default=os.environ.get("CI_REUSE", "{}"))
    args = parser.parse_args()
    try:
        if args.command == "plan":
            event = load_json(args.event.read_text())
            event_name = os.environ["GITHUB_EVENT_NAME"]
            paths = []
            if event_name == "pull_request":
                pr = event["pull_request"]
                paths = changed_paths(args.root, pr["base"]["sha"], pr["head"]["sha"])
            plan = make_plan(event_name, event, paths)
            validate_plan(plan)
            proof = load_json(args.reuse_proof_json)
            reused = reused_jobs(plan, proof)
            if reused and (event_name != "push" or event.get("ref") != "refs/heads/main" or proof["main"] != event.get("after")):
                raise ValueError("reused proof is not for this main push")
            payload = json.dumps(plan, separators=(",", ":"))
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(payload + "\n")
            if "GITHUB_OUTPUT" in os.environ:
                with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
                    stream.write("plan=" + payload + "\n")
                    for job, selected in plan["jobs"].items():
                        stream.write(job + "=" + str(selected and job not in reused).lower() + "\n")
            print(json.dumps(plan, indent=2))
        elif args.command == "evaluate-documentation":
            evaluate_documentation(load_json(args.plan_json), load_json(args.needs_json))
            print("Build Documentation: planned documentation requirement satisfied.")
        else:
            proof = load_json(args.reuse_proof_json)
            reuse = reuse_policy()
            reuse.validate_proof(proof)
            if proof:
                event = load_json(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
                reuse.revalidate(proof, event, os.environ)
            evaluate(load_json(args.plan_json), load_json(args.needs_json), proof)
            print("CI Required: every logical contract has fresh success or revalidated exact-tree PR evidence; no unexplained skips.")
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(f"CI policy rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
