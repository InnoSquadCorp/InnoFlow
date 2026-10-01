"""Executable impact matrix and fail-closed Git/result negative controls."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci-policy.py"
spec = importlib.util.spec_from_file_location("ci_policy", SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def pr(labels=(), action="opened", author="contributor"):
    return {"action": action, "pull_request": {
        "labels": [{"name": x} for x in labels], "user": {"login": author},
    }}


def results(plan):
    return {"ci-plan": {"result": "success"}, **{
        job: {"result": "success" if selected else "skipped"}
        for job, selected in plan["jobs"].items()
    }}


def selected(plan):
    return {job for job, active in plan["jobs"].items() if active}


class SelectionTests(unittest.TestCase):
    def test_impact_matrix(self):
        docs = {"policy", "docs-required", "lint", "documentation"}
        cases = [
            (["README.md"], docs), ([".spi.yml"], docs), (["docs/MACRO_OPERATIONS.md"], docs),
            (["Tools/generate-docc.sh"], docs),
            (["docs/contracts/doc-swift-fence-review.tsv"], docs),
            (["scripts/check-doc-copyable-examples.rb"], docs),
            ([".github/workflows/docs.yml"], docs),
            ([".github/workflows/docs-publish.yml"], docs),
            ([".github/workflows/coverage.yml"], {"policy", "docs-required", "coverage"}),
            ([".github/workflows/asan.yml"], {"policy", "docs-required", "lint", "address-sanitizer"}),
            ([".github/dependabot.yml"], {"policy", "docs-required"}),
            ([".github/ISSUE_TEMPLATE/bug_report.md"], {"policy", "docs-required"}),
            ([".github/workflows/dependabot-auto-merge.yml"], {"policy", "docs-required"}),
            ([".github/workflows/dependabot-review-notice.yml"], {"policy", "docs-required"}),
            ([".github/workflows/dependabot-ready.yml"], {"policy", "docs-required"}),
            (["docs/contracts/coverage-policy.json"], set(policy.JOBS)),
            (["docs/contracts/runtime-test-inventory.json"], set(policy.JOBS)),
            (["docs/contracts/release-evidence-policy.json"], set(policy.JOBS)),
            (["docs/contracts/future.json"], set(policy.JOBS)),
            (["docs/unknown.swift"], set(policy.JOBS)),
            (["scripts/ci-policy.py"], set(policy.JOBS)),
            (["scripts/tests/test_ci_policy.py"], set(policy.JOBS)),
            ([".swift-format"], set(policy.JOBS)),
            (["Package.swift"], set(policy.JOBS)),
            (["Package.resolved"], set(policy.JOBS)),
            (["future/new-script"], set(policy.JOBS)),
            ([".github/workflows/future.yml"], set(policy.JOBS)),
            ([".github/workflows/nested/coverage.yml"], set(policy.JOBS)),
            ([".github/actions/setup/action.yml"], set(policy.JOBS)),
            ([], set(policy.JOBS)),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                plan = policy.make_plan("pull_request", pr(), paths)
                policy.validate_plan(plan)
                self.assertEqual(selected(plan), expected)
                policy.evaluate(plan, results(plan))

    def test_source_tests_examples_preserve_every_existing_gate(self):
        paths = [
            "Sources/InnoFlowCore/Store.swift", "Sources/InnoFlowMacros/InnoFlowMacro.swift",
            "Sources/InnoFlowSwiftUI/Store+SwiftUIBindings.swift", "Sources/InnoFlowTesting/TestStore.swift",
            "Sources/InnoFlow/InnoFlow.docc/InnoFlow.md", "Sources/README.md",
            "Tests/InnoFlowTests/ManualTestClockTests.swift", "Tests/README.md",
            "Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Package.swift",
            "Examples/InnoFlowSampleApp/InnoFlowSampleApp.xcodeproj/project.pbxproj",
            "Examples/README.md", "Plugins/future/plugin.swift", "Repro/scenario.swift",
        ]
        for path in paths:
            with self.subTest(path=path):
                plan = policy.make_plan("pull_request", pr(), [path])
                self.assertEqual(selected(plan), set(policy.JOBS))
                for job in policy.JOBS:
                    reduced = copy.deepcopy(plan)
                    reduced["jobs"][job] = False
                    with self.subTest(suppressed=job), self.assertRaises(ValueError):
                        policy.evaluate(reduced, results(reduced))

    def test_pr_lifecycle_bot_and_label_transitions(self):
        for action in policy.PR_ACTIONS:
            for labels in [[], ["dependencies"], ["run-asan"], ["release-validation"], ["run-asan", "release-validation"]]:
                for author in ["contributor", "dependabot[bot]"]:
                    plan = policy.make_plan("pull_request", pr(labels, action, author), [".github/dependabot.yml"])
                    expected = {"policy", "docs-required"}
                    if "run-asan" in labels:
                        expected |= {"lint", "address-sanitizer"}
                    if "release-validation" in labels or author == "dependabot[bot]":
                        expected = set(policy.JOBS)
                    with self.subTest(action=action, labels=labels, author=author):
                        self.assertEqual(selected(plan), expected)
                        policy.evaluate(plan, results(plan))
        # Removing the opt-in label recomputes the current exact change selection.
        removed = policy.make_plan("pull_request", pr(action="unlabeled"), ["README.md"])
        self.assertFalse(removed["jobs"]["address-sanitizer"])

    def test_full_branches_queue_dispatch_and_empty_diff(self):
        for name, event in [
                ("push", {"ref": "refs/heads/main"}),
                ("push", {"ref": "refs/heads/develop"}),
                ("push", {"ref": "refs/heads/trunk", "repository": {"default_branch": "trunk"}}),
                ("merge_group", {"action": "checks_requested"}),
                ("workflow_dispatch", {}),
                ("workflow_dispatch", {"inputs": {"dependabot_merge_pr": "123"}})]:
            with self.subTest(name=name, event=event):
                plan = policy.make_plan(name, event, [".github/dependabot.yml"])
                self.assertTrue(all(plan["jobs"].values()))
                policy.evaluate(plan, results(plan))
        self.assertTrue(all(policy.make_plan("pull_request", pr(), [])["jobs"].values()))

    def test_bad_events_and_paths_reject_without_optimistic_plan(self):
        bad_events = [
            ("pull_request", {}, []),
            ("pull_request", {"action": "opened", "pull_request": {}}, []),
            ("pull_request", pr(action="closed"), []),
            ("pull_request", pr(action="ready_for_review"), []),
            ("pull_request", pr(), None), ("push", {"ref": "refs/heads/topic"}, []),
            ("push", {"ref": "refs/heads/main", "repository": []}, []),
            ("merge_group", {"action": "destroyed"}, []),
            ("pull_request_target", pr(), []), ("schedule", {}, []),
        ]
        for name, event, paths in bad_events:
            with self.subTest(event=event), self.assertRaises(ValueError):
                policy.make_plan(name, event, paths)
        for change in [None, [], {}, {"name": False}]:
            event = pr()
            event["pull_request"]["labels"] = change
            if change == []:
                continue
            with self.assertRaises(ValueError):
                policy.make_plan("pull_request", event, [])
        for user in [None, [], {}, {"login": None}, {"login": ""}]:
            event = pr()
            event["pull_request"]["user"] = user
            with self.assertRaises(ValueError):
                policy.make_plan("pull_request", event, [])
        for path in ["../Package.swift", "/Package.swift", "x/../../README.md", "a\nvalue=false",
                     "a\rvalue=false", "a\x00b", "a\\b", "a//b", "./README.md", "", None]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                policy.make_plan("pull_request", pr(), [path])

    def test_transitive_execution_dependencies_are_preserved(self):
        self.assertEqual(policy.with_dependencies({"sample-ui-tests"}), {"policy", "docs-required", "lint", "sample-build", "sample-ui-tests"})
        self.assertEqual(policy.with_dependencies({"principle-gates"}), {"policy", "docs-required", "lint", "coverage", "principle-gates"})
        self.assertEqual(policy.with_dependencies({"sample-package-builds"}), {"policy", "docs-required", "lint", "sample-tests", "sample-package-builds"})


class GitDiffTests(unittest.TestCase):
    def test_real_git_deleted_renamed_changed_paths_cli_and_missing_anchor(self):
        with tempfile.TemporaryDirectory(prefix="innoflow-ci-diff-") as directory:
            root = Path(directory)
            env = dict(os.environ, GIT_AUTHOR_NAME="Fixture", GIT_COMMITTER_NAME="Fixture",
                       GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_EMAIL="fixture@example.invalid")
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, "-c", "commit.gpgsign=false", *args], env=env, text=True).strip()
            git("init", "-q", "-b", "main")
            (root / "Sources").mkdir()
            (root / "Sources/deleted.swift").write_text("struct Deleted {}\n")
            (root / "Sources/renamed.swift").write_text("struct Renamed {}\n" * 20)
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (root / "Sources/deleted.swift").unlink()
            (root / "Sources/renamed.swift").rename(root / "renamed.md")
            git("add", "-A")
            git("commit", "-qm", "delete and rename source to docs")
            head = git("rev-parse", "HEAD")
            paths = policy.changed_paths(root, base, head)
            self.assertEqual(set(paths), {"Sources/deleted.swift", "Sources/renamed.swift", "renamed.md"})
            self.assertEqual(policy.changed_paths(root, head, head), [])
            plan = policy.make_plan("pull_request", pr(), paths)
            self.assertTrue(all(plan["jobs"].values()))
            event = pr(action="synchronize")
            event["pull_request"].update(base={"sha": base}, head={"sha": head})
            event_file, output, github_output = root / "event.json", root / "plan.json", root / "github-output"
            event_file.write_text(json.dumps(event))
            cmd = [sys_executable(), str(SCRIPT), "plan", "--event", str(event_file), "--root", directory, "--output", str(output)]
            proc = subprocess.run(cmd, env={**env, "GITHUB_EVENT_NAME": "pull_request", "GITHUB_OUTPUT": str(github_output)}, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(output.read_text()), plan)
            self.assertIn("plan=", github_output.read_text())
            for job in policy.JOBS:
                self.assertIn(f"{job}=true\n", github_output.read_text())
            output.unlink()
            github_output.unlink()
            event["pull_request"]["head"]["sha"] = "1" * 40
            event_file.write_text(json.dumps(event))
            proc = subprocess.run(cmd, env={**env, "GITHUB_EVENT_NAME": "pull_request", "GITHUB_OUTPUT": str(github_output)}, capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(output.exists())
            self.assertFalse(github_output.exists())

    def test_nul_status_stream_rename_copy_and_malformed_fail_closed(self):
        for stream in [b"R100\0Sources/old.swift\0docs/new.md\0", b"C075\0Sources/old.swift\0docs/new.md\0"]:
            with mock.patch.object(policy.subprocess, "check_output", return_value=stream):
                self.assertEqual(policy.changed_paths(ROOT, "1" * 40, "2" * 40), ["Sources/old.swift", "docs/new.md"])
        for stream in [b"M\0README.md", b"R100\0README.md\0", b"X\0README.md\0", b"U\0README.md\0", b"M\0\0", b"M\0\xff\0"]:
            with self.subTest(stream=stream), mock.patch.object(policy.subprocess, "check_output", return_value=stream):
                with self.assertRaises(ValueError):
                    policy.changed_paths(ROOT, "1" * 40, "2" * 40)
        for base, head in [("main", "2" * 40), ("1" * 39, "2" * 40), ("1" * 40, "HEAD"), (None, "2" * 40)]:
            with self.assertRaises(ValueError):
                policy.changed_paths(ROOT, base, head)


def sys_executable():
    import sys
    return sys.executable


class RequiredTests(unittest.TestCase):
    def test_all_job_results_reject_failure_cancel_missing_wrong_skip(self):
        for paths in [["README.md"], ["Sources/InnoFlowCore/Store.swift"]]:
            plan = policy.make_plan("pull_request", pr(), paths)
            policy.evaluate(plan, results(plan))
            for job in ("ci-plan", *policy.JOBS):
                expected = results(plan)[job]["result"]
                for status in ["failure", "cancelled", "timed_out", "neutral", "", None,
                               "skipped" if expected == "success" else "success"]:
                    needs = results(plan)
                    needs[job]["result"] = status
                    with self.subTest(job=job, status=status), self.assertRaises(ValueError):
                        policy.evaluate(plan, needs)
                needs = results(plan)
                del needs[job]
                with self.assertRaises(ValueError):
                    policy.evaluate(plan, needs)
            needs = results(plan)
            needs["unplanned"] = {"result": "success"}
            with self.assertRaises(ValueError):
                policy.evaluate(plan, needs)

    def test_plan_tampering_and_incomplete_evidence_fail_closed(self):
        original = policy.make_plan("pull_request", pr(), ["Package.swift"])
        mutations = [lambda p: p["jobs"].pop("coverage"),
                     lambda p: p["jobs"].update(coverage=False),
                     lambda p: p["jobs"].update(policy=False),
                     lambda p: p["jobs"].update(policy="true"),
                     lambda p: p.update(schema=2), lambda p: p.update(schema=True),
                     lambda p: p.update(lane="unrecognized"), lambda p: p.update(requested=["coverage"]),
                     lambda p: p.update(changes=None), lambda p: p.update(unknown=True),
                     lambda p: p["changes"][0].update(reason="documentation")]
        for mutate in mutations:
            plan = copy.deepcopy(original)
            mutate(plan)
            with self.assertRaises(ValueError):
                policy.evaluate(plan, results(plan))
        docs = policy.make_plan("pull_request", pr(), ["README.md"])
        for mutate in [lambda p: p.update(lane="full"), lambda p: p.update(lane="release-validation"),
                       lambda p: p.update(changes=[]), lambda p: p.update(requested=["address-sanitizer"]),
                       lambda p: p["jobs"].update(coverage=True)]:
            mutated = copy.deepcopy(docs)
            mutate(mutated)
            with self.assertRaises(ValueError):
                policy.evaluate(mutated, results(mutated))
        for value in ["", "{}", "null", "{invalid", json.dumps({**original, "unknown": True}), '{"schema":1,"schema":1}']:
            proc = subprocess.run([sys_executable(), str(SCRIPT), "evaluate"],
                                  env={**os.environ, "CI_PLAN": value, "CI_NEEDS": json.dumps(results(original))}, capture_output=True)
            self.assertNotEqual(proc.returncode, 0)

    def test_matrix_and_reusable_failure_cannot_be_skipped(self):
        plan = policy.make_plan("pull_request", pr(), ["Package.swift"])
        for job in ["documentation", "coverage", "package-builds", "focused-runtime-tests", "sample-package-builds"]:
            for status in ["failure", "cancelled", "skipped"]:
                needs = results(plan)
                needs[job]["result"] = status
                with self.subTest(job=job, status=status), self.assertRaises(ValueError):
                    policy.evaluate(plan, needs)

    def test_protected_documentation_bridge_obeys_exact_plan(self):
        for paths in [["README.md"], [".github/dependabot.yml"], ["Sources/InnoFlowCore/Store.swift"]]:
            plan = policy.make_plan("pull_request", pr(), paths)
            needs = {job: results(plan)[job] for job in ("ci-plan", "documentation")}
            policy.evaluate_documentation(plan, needs)
            for job in needs:
                expected = needs[job]["result"]
                for status in ["failure", "cancelled", "neutral", "", None,
                               "skipped" if expected == "success" else "success"]:
                    bad = copy.deepcopy(needs)
                    bad[job]["result"] = status
                    with self.subTest(paths=paths, job=job, status=status), self.assertRaises(ValueError):
                        policy.evaluate_documentation(plan, bad)
                bad = copy.deepcopy(needs)
                del bad[job]
                with self.assertRaises(ValueError):
                    policy.evaluate_documentation(plan, bad)
            with self.assertRaises(ValueError):
                policy.evaluate_documentation(plan, {**needs, "unexpected": {"result": "success"}})
            proc = subprocess.run([sys_executable(), str(SCRIPT), "evaluate-documentation"],
                                  env={**os.environ, "CI_PLAN": json.dumps(plan), "CI_NEEDS": json.dumps(needs)}, capture_output=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_cli_success_and_duplicate_needs_fail_closed(self):
        plan = policy.make_plan("workflow_dispatch", {}, [])
        proc = subprocess.run([sys_executable(), str(SCRIPT), "evaluate"],
                              env={**os.environ, "CI_PLAN": json.dumps(plan), "CI_NEEDS": json.dumps(results(plan))}, capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with self.assertRaises(ValueError):
            policy.load_json('{"policy":{"result":"failure"},"policy":{"result":"success"}}')


if __name__ == "__main__":
    unittest.main()
