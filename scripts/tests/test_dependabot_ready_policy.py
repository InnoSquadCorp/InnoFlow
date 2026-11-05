"""Adversarial native Ready attribution, verdict and bounded-rerun contracts."""
import contextlib
import copy
from datetime import datetime, timezone, timedelta
import importlib.util
import json
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock
import urllib.parse

from test_dependabot_merge_policy import Transcript, p, HEAD, BASE, NUMBER, RUN, READY_RUN, NATIVE_RUN, TRUSTED

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_ready', ROOT / 'scripts/dependabot-ready-policy.py')
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)


class NativeReadyTests(unittest.TestCase):
    def setUp(self):
        self.api = Transcript()
        self.env = mock.patch.dict(os.environ, TRUSTED, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def verdict(self, ready, api=None):
        api = api or self.api
        result = 'success' if ready else 'failure'
        api.native_run.update(status='completed', conclusion=result)
        api.native_job.update(status='completed', conclusion=result)
        api.native_check.update(status='completed', conclusion=result)
        for step in api.native_job['steps']:
            step.update(status='completed', conclusion='success')
        api.native_job['steps'][-1]['conclusion'] = result

    def running(self):
        for item in [self.api.native_run, self.api.native_job, self.api.native_check]:
            item.update(status='in_progress', conclusion=None)
        self.api.native_job['steps'][1].update(status='in_progress', conclusion=None)
        self.api.native_job['steps'][-1].update(status='queued', conclusion=None)

    def snapshot(self, enabled=True, overrides=None, event_pr=None):
        with tempfile.TemporaryDirectory() as directory:
            event = Path(directory) / 'event.json'
            event.write_text(json.dumps({'pull_request': self.api.pr if event_pr is None else event_pr}))
            environment = dict(GITHUB_WORKFLOW_REF=p.REPOSITORY + '/' + n.REPORTER_PATH + '@refs/heads/main',
                               GITHUB_EVENT_NAME='pull_request_target', GITHUB_JOB='ready', GITHUB_RUN_ID=str(NATIVE_RUN),
                               GITHUB_WORKFLOW_SHA=BASE, GITHUB_EVENT_PATH=str(event))
            environment.update(overrides or {})
            with mock.patch.dict(os.environ, **environment):
                return n.snapshot(self.api, p, NUMBER, enabled)

    def writer(self):
        self.api.pr['user'] = dict(id=1, login='human', type='User')
        self.verdict(False)
        target = n.refresh_plan(self.api, p, NUMBER, False)
        self.api.ready_run.update(event='workflow_run', created_at=self.api.native_run['created_at'], status='in_progress')
        self.api.refresh_writers = [self.api.ready_run]
        self.api.ready_jobs[(READY_RUN, 1)] = [dict(id=7777, name=n.claim_name(target), status='in_progress', conclusion=None,
            started_at=self.api.native_run['created_at'],
            steps=[dict(name=n.REQUEST_STEP, status='in_progress', conclusion=None)])]
        os.environ.update(GITHUB_JOB='ready-refresh', GITHUB_EVENT_NAME='workflow_run', GITHUB_WORKFLOW_SHA=BASE)
        return target

    def write(self, target, enabled=False):
        # The workflow: a verifying preflight step, then a POST-only request step.
        request, reason = n.preflight(self.api, p, target, enabled)
        self.assertTrue(request, reason)
        return n.refresh(self.api, p, target)

    def fork(self):
        self.api.pr['user'] = dict(login='human', id=1, type='User')
        self.api.pr['head']['repo'] = dict(id=101, full_name='contributor/InnoFlow', fork=True)
        self.api.native_run['head_repository'] = self.api.pr['head']['repo']
        self.api.native_run['pull_requests'] = []
        self.api.native_run['display_title'] = (
            f'Ready v1 pr:{NUMBER} head:{HEAD} head-repo:101 base-repo:100 base:main source:{BASE}')
        self.api.native_job['steps'][1]['name'] = (n.SOURCE_STEP + BASE + ' for ' +
                                                  self.api.native_run['display_title'].rsplit(' source:', 1)[0])

    def test_fork_without_rest_association_uses_trusted_event_binding(self):
        self.fork()
        self.assertEqual(n.latest(self.api, p, NUMBER, HEAD)['id'], NATIVE_RUN)
        self.assertEqual(n.require_success(self.api, p, NUMBER, HEAD), (NATIVE_RUN, 1, 9000))
        self.assertIsNone(n.refresh_plan(self.api, p, NUMBER, False))
        self.running()
        self.assertTrue(self.snapshot(False)[0])
        self.assertFalse(self.api.mutations)

    def test_fork_refresh_readback_preserves_event_binding_without_links(self):
        self.fork()
        target = self.writer()
        def advance(method, path, payload):
            self.api.mutations.append((method, path, payload))
            self.api.native_run.update(run_attempt=2, status='queued', conclusion=None)
        with mock.patch.object(self.api, 'mutate', side_effect=advance):
            self.assertIn('Verified native reporter rerun requested', self.write(target))
        self.assertEqual(len(self.api.mutations), 1)

    def test_snapshot_rejects_stale_or_foreign_event_payload(self):
        self.fork()
        self.running()
        for mutation in [lambda pr: pr['head'].update(sha=BASE), lambda pr: pr['head'].update(ref='other'),
                         lambda pr: pr['head']['repo'].update(id=999), lambda pr: pr['base'].update(ref='other'),
                         lambda pr: pr['base']['repo'].update(id=999), lambda pr: pr.update(number=NUMBER + 1)]:
            event_pr = copy.deepcopy(self.api.pr)
            mutation(event_pr)
            with self.assertRaises(p.Rejected): self.snapshot(False, event_pr=event_pr)
        self.assertFalse(self.api.mutations)

    def test_fork_event_binding_rejects_mismatches_and_untrusted_source(self):
        for old, replacement in [(f'pr:{NUMBER}', f'pr:{NUMBER + 1}'), (f'head:{HEAD}', f'head:{BASE}'),
                                 ('head-repo:101', 'head-repo:102'), ('base-repo:100', 'base-repo:101'),
                                 ('base:main', 'base:other'), (f'source:{BASE}', f'source:{HEAD}'),
                                 ('Ready v1', 'PR title that looks like Ready v1')]:
            self.api = Transcript()
            self.fork()
            self.api.native_run['display_title'] = self.api.native_run['display_title'].replace(old, replacement)
            with self.subTest(old=old), self.assertRaises(p.Rejected):
                n.require_success(self.api, p, NUMBER, HEAD)
            self.assertFalse(self.api.mutations)
        for field, value in [('head_branch', 'other'), ('event', 'workflow_dispatch'), ('workflow_id', 999)]:
            self.api = Transcript()
            self.fork()
            self.api.native_run[field] = value
            with self.subTest(field=field), self.assertRaises(p.Rejected):
                n.require_success(self.api, p, NUMBER, HEAD)

    def test_present_association_cannot_be_overridden_by_event_binding(self):
        self.fork()
        self.api.native_run['pull_requests'] = [dict(number=NUMBER, head=dict(sha=BASE),
                                                    base=dict(ref='main', repo=self.api.repo))]
        with self.assertRaises(p.Rejected): n.require_success(self.api, p, NUMBER, HEAD)

    def test_fork_cannot_reuse_old_success_when_newer_binding_is_missing(self):
        self.fork()
        newer = copy.deepcopy(self.api.native_run)
        newer.update(id=NATIVE_RUN + 1, run_number=41, display_title='unbound current reporter')
        self.api.native_runs.append(newer)
        with self.assertRaises(p.Rejected): n.require_success(self.api, p, NUMBER, HEAD)

    def test_fork_binding_source_must_match_job_and_snapshot_environment(self):
        self.fork()
        self.api.native_job['steps'][1]['name'] = n.SOURCE_STEP + HEAD
        with self.assertRaises(p.Rejected): n.require_success(self.api, p, NUMBER, HEAD)
        self.running()
        with self.assertRaises(p.Rejected): self.snapshot(False, overrides={'GITHUB_WORKFLOW_SHA': HEAD})

    def test_fork_historical_binding_survives_policy_upgrade_but_latest_must_be_current(self):
        self.fork()
        old = copy.deepcopy(self.api.native_run)
        old.update(id=NATIVE_RUN - 1, run_number=39, check_suite_id=901)
        old_job = copy.deepcopy(self.api.native_job)
        old_job.update(id=9101, check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/9100')
        old_check = dict(self.api.native_check, id=9100, check_suite=dict(id=901),
                        details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{NATIVE_RUN - 1}/job/9101')
        self.api.native_runs.append(old)
        self.api.native_jobs[(NATIVE_RUN - 1, 1)] = [old_job]
        self.api.checks.append(old_check)
        self.api.base = HEAD
        self.api.source_blobs[f'contents/scripts/dependabot-ready-policy.py?ref={BASE}'] = 'e' * 40
        self.api.native_run['display_title'] = self.api.native_run['display_title'].replace('source:' + BASE, 'source:' + HEAD)
        self.api.native_job['steps'][1]['name'] = self.api.native_job['steps'][1]['name'].replace(BASE, HEAD)
        original_get = self.api.get
        def get(route):
            if 'compare/' in route:
                source = route.split('compare/', 1)[1].split('...')[0]
                return dict(status='identical' if source == HEAD else 'ahead', merge_base_commit=dict(sha=source))
            return original_get(route)
        with mock.patch.object(self.api, 'get', side_effect=get):
            self.assertEqual(n.verified_check_ids(self.api, p, NUMBER, HEAD), {9000, 9100})
            self.assertEqual(n.require_success(self.api, p, NUMBER, HEAD), (NATIVE_RUN, 1, 9000))
            with self.assertRaises(p.Rejected): n.source_compatible(self.api, p, BASE)

    def test_run_title_alone_cannot_replace_native_event_step(self):
        self.fork()
        self.api.native_job['steps'][1]['name'] = n.SOURCE_STEP + BASE
        with self.assertRaises(p.Rejected): n.require_success(self.api, p, NUMBER, HEAD)
        with self.assertRaises(p.Rejected): n.verified_check_ids(self.api, p, NUMBER, HEAD)
        self.assertFalse(self.api.mutations)
        self.api = Transcript()
        self.api.native_job['steps'][1]['name'] += ' unbound suffix'
        with self.assertRaises(p.Rejected): n.require_success(self.api, p, NUMBER, HEAD)

    def test_reporter_requires_receipt_for_bots_and_remains_readonly_for_manual_prs(self):
        self.running()
        self.assertFalse(self.snapshot()[0])  # Full CI alone cannot release the native barrier.
        self.assertFalse(self.api.mutations)
        self.api.run['conclusion'] = 'failure'
        self.assertFalse(self.snapshot()[0])
        self.assertFalse(self.api.mutations)
        self.api.pr['user'] = dict(login='human', id=1, type='User')
        self.assertTrue(self.snapshot(False)[0])
        self.assertFalse(self.api.mutations)

    def test_standby_and_caught_proof_failure_are_false_not_coordinate_success(self):
        self.running()
        self.assertFalse(self.snapshot(False)[0])
        with mock.patch.object(p, 'proof', side_effect=p.Rejected('missing full CI')):
            verdict, reason = self.snapshot()
        self.assertFalse(verdict)
        self.assertIn('missing full CI', reason)
        with mock.patch.object(p, 'proof', side_effect=OSError('API unavailable')):
            with self.assertRaises(OSError): self.snapshot()
        self.assertFalse(self.api.mutations)
        source = (ROOT / n.REPORTER_PATH).read_text()
        self.assertIn('run: test "$READY" = \'true\'', source)
        self.assertNotIn(' coordinate ', source)
        self.assertNotIn('continue-on-error', source)

    def test_running_snapshot_does_not_require_future_step_metadata(self):
        self.api.pr['user'] = dict(login='human', id=1, type='User')
        self.running()
        self.api.native_job['steps'] = self.api.native_job['steps'][:2]
        self.assertTrue(self.snapshot()[0])
        self.assertFalse(self.api.mutations)

    def test_superseded_cancelled_empty_run_is_ignored_without_exempting_orphans(self):
        previous = copy.deepcopy(self.api.native_run)
        previous.update(id=NATIVE_RUN - 1, run_number=39, conclusion='cancelled')
        self.api.native_runs.append(previous)
        self.api.native_jobs[(NATIVE_RUN - 1, 1)] = []
        p.proof(self.api, NUMBER)
        orphan = dict(self.api.native_check, id=9999, conclusion='cancelled')
        self.api.checks.append(orphan)
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)
        self.api.checks.pop()
        previous['conclusion'] = 'failure'
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_source_and_native_check_identity_controls(self):
        changes = [lambda a: a.native_run.update(path=p.CI_PATH), lambda a: a.native_run.update(event='workflow_dispatch'),
                   lambda a: a.native_run.update(head_sha=BASE), lambda a: a.native_run.update(workflow_id=999),
                   lambda a: a.native_run.update(pull_requests=[]), lambda a: a.native_run['pull_requests'][0]['base'].update(ref='other'),
                   lambda a: a.native_check['app'].update(id=999), lambda a: a.native_check['check_suite'].update(id=999),
                   lambda a: a.native_check.update(head_sha=BASE), lambda a: a.native_check.update(details_url='https://example.invalid'),
                   lambda a: a.native_job.update(name='CI Required'), lambda a: a.native_job.update(check_run_url='https://evil.test/9000'),
                   lambda a: a.native_job.update(steps=[]), lambda a: a.native_jobs[(NATIVE_RUN, 1)].append(copy.deepcopy(a.native_job))]
        for change in changes:
            api = Transcript()
            change(api)
            with self.subTest(change=change), self.assertRaises(p.Rejected):
                n.require_success(api, p, NUMBER, HEAD)
            self.assertFalse(api.mutations)

    def test_native_jobs_cannot_be_skipped_neutral_or_infrastructure_failed(self):
        for result in ['skipped', 'neutral', 'cancelled', 'timed_out', None]:
            api = Transcript()
            api.native_run['conclusion'] = result
            with self.assertRaises(p.Rejected): n.require_success(api, p, NUMBER, HEAD)
        for index in [0, 1]:
            api = Transcript()
            self.verdict(False, api)
            api.native_job['steps'][index]['conclusion'] = 'failure'
            with self.assertRaises(p.Rejected): n.refresh_plan(api, p, NUMBER, True)
        self.verdict(False)
        self.assertIsNone(n.refresh_plan(self.api, p, NUMBER, False))

    def test_cancelled_latest_and_newer_attempt_never_fall_back(self):
        newer = copy.deepcopy(self.api.native_run)
        newer.update(id=NATIVE_RUN + 1, run_number=41, conclusion='cancelled')
        self.api.native_runs.append(newer)
        self.api.native_jobs[(NATIVE_RUN + 1, 1)] = []
        with self.assertRaises(p.Rejected): n.require_success(self.api, p, NUMBER, HEAD)
        self.assertFalse(self.api.mutations)
        self.api = Transcript()
        self.api.native_run['run_attempt'] = 2
        with self.assertRaises(p.Rejected): n.require_success(self.api, p, NUMBER, HEAD)

    def test_historical_native_attempts_are_attributed_without_self_dependency(self):
        self.api.native_run['run_attempt'] = 2
        previous = self.api.native_job
        current = copy.deepcopy(previous)
        current.update(id=9003, check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/9002')
        previous.update(status='completed', conclusion='cancelled', steps=[])
        self.api.native_check.update(conclusion='cancelled')
        check = dict(self.api.native_check, id=9002, conclusion='success', details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{NATIVE_RUN}/job/9003')
        self.api.checks.append(check)
        self.api.native_jobs[(NATIVE_RUN, 2)] = [current]
        self.assertEqual(n.verified_check_ids(self.api, p, NUMBER, HEAD), {9000, 9002})
        p.proof(self.api, NUMBER)
        check['check_suite'] = dict(id=999)
        with self.assertRaises(p.Rejected): p.proof(self.api, NUMBER)

    def test_legacy_api_ready_or_same_name_lookalike_never_counts(self):
        for legacy in [dict(external_id=f'dependabot-policy:{NUMBER}:{HEAD}'), dict(external_id='unrelated')]:
            api = Transcript()
            api.checks.append(dict(api.native_check, id=9999, **legacy))
            with self.assertRaises(p.Rejected): p.proof(api, NUMBER)
        self.api.native_job['check_run_url'] = f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/9999'
        with self.assertRaises((p.Rejected, StopIteration)): n.require_success(self.api, p, NUMBER, HEAD)

    def test_source_compatibility_compares_exact_trusted_workflow_and_code_blobs(self):
        self.api.base = 'e' * 40
        for path in [n.REPORTER_PATH, p.COORDINATOR_PATH, 'scripts/dependabot-ready-policy.py', 'scripts/dependabot-merge-policy.py', 'scripts/ci-metadata-policy.py']:
            self.api.source_blobs = {f'contents/{path}?ref={self.api.base}': 'f' * 40}
            with self.assertRaisesRegex(p.Rejected, 'obsolete'): n.source_compatible(self.api, p, BASE)
        self.api.source_blobs = {}
        original = self.api.get
        with mock.patch.object(self.api, 'get', side_effect=lambda path: dict(status='diverged', merge_base_commit=dict(sha=HEAD)) if '/compare/' in path else original(path)):
            with self.assertRaisesRegex(p.Rejected, 'ancestry'): n.source_compatible(self.api, p, BASE)
        self.assertFalse(self.api.mutations)

    def test_snapshot_rejects_obsolete_or_cancelled_self_before_success(self):
        self.running()
        with mock.patch.object(n, 'desired', side_effect=lambda *a: (self.api.native_run.update(status='completed', conclusion='cancelled') or (True, 'race'))):
            with self.assertRaises(p.Rejected): self.snapshot()
        self.api = Transcript()
        self.running()
        self.api.native_run['run_attempt'] = 2
        with self.assertRaises(p.Rejected): self.snapshot()
        self.assertFalse(self.api.mutations)

    def test_running_and_unchanged_verdicts_never_spend_reruns(self):
        self.assertIsNotNone(n.refresh_plan(self.api, p, NUMBER, True))  # Green/unarmed must fail before arming.
        self.verdict(False)
        self.assertIsNone(n.refresh_plan(self.api, p, NUMBER, True))
        self.running()
        self.assertIsNone(n.refresh_plan(self.api, p, NUMBER, True))
        self.verdict(False)
        self.assertIsNone(n.refresh_plan(self.api, p, NUMBER, False))
        self.assertFalse(self.api.mutations)

    def test_refresh_targets_only_exact_dedicated_job_once(self):
        target = self.writer()
        def advance(method, path, payload):
            self.api.mutations.append((method, path, payload))
            self.api.native_run.update(run_attempt=2, status='queued', conclusion=None)
        with mock.patch.object(self.api, 'mutate', side_effect=advance), mock.patch.object(n.time, 'sleep'):
            self.assertIn('Verified', self.write(target))
        self.assertEqual(self.api.mutations, [('POST', p.route('actions/jobs/9001/rerun'), {})])
        self.assertNotIn('macro-tests', self.api.mutations[0][1])

    def test_wrong_job_head_attempt_workflow_and_writer_context_never_post(self):
        # The workflow feeds both steps the same matrix target; preflight owns
        # every tuple check, so a mismatch never reaches the request step.
        for mutate in [lambda t: t.update(job=2000), lambda t: t.update(run=RUN), lambda t: t.update(head=BASE),
                       lambda t: t.update(attempt=2), lambda t: t.update(pr=True), lambda t: t.update(extra=1)]:
            self.api = Transcript()
            target = self.writer()
            mutate(target)
            with self.assertRaises(p.Rejected): n.preflight(self.api, p, target, False)
            self.assertFalse(self.api.mutations)
        for mutate in [lambda t: t.update(pr=True), lambda t: t.update(extra=1), lambda t: t.update(head='x')]:
            self.api = Transcript()
            target = self.writer()
            mutate(target)
            with self.assertRaisesRegex(p.Rejected, 'invalid refresh target'): n.refresh(self.api, p, target)
            self.assertFalse(self.api.mutations)
        for key, value in [('GITHUB_REF', 'refs/heads/unsafe'), ('GITHUB_WORKFLOW_REF', 'foreign'), ('GITHUB_JOB', 'bot-ready'),
                           ('GITHUB_EVENT_NAME', 'pull_request_target')]:
            self.api = Transcript()
            target = self.writer()
            with mock.patch.dict(os.environ, **{key:value}):
                with self.assertRaises(p.Rejected): n.preflight(self.api, p, target, False)
                with self.assertRaises(p.Rejected): n.refresh(self.api, p, target)
            self.assertFalse(self.api.mutations)

    def test_refresh_limits_and_unknown_sources_block_without_retry(self):
        for field, value in [('created_at', (datetime.now(timezone.utc) - timedelta(days=31)).isoformat()), ('run_attempt', 50)]:
            self.api = Transcript()
            target = self.writer()
            self.api.native_run[field] = value
            if field == 'run_attempt':
                self.api.native_jobs[(NATIVE_RUN, 50)] = [self.api.native_job]
                target['attempt'] = 50
            with self.assertRaises(p.Rejected): n.preflight(self.api, p, target, False)
            self.assertFalse(self.api.mutations)

    def test_request_step_posts_before_any_read_so_execution_means_attempt(self):
        # 2026-11-04: the request step re-ran the whole preflight (proof pairs,
        # receipts, claim history) and the job timeout cut it before any POST.
        # Its executed step then blocked the tuple until a manual reporter rerun.
        target = self.writer()
        self.assertTrue(n.preflight(self.api, p, target, False)[0])
        calls = []
        original_get = self.api.get
        def get(route):
            calls.append(('GET', route))
            return original_get(route)
        def pages(route, key=None):
            calls.append(('PAGES', route))
            raise AssertionError('request step must not page history or proofs')
        def advance(method, path, payload):
            calls.append((method, path))
            self.api.native_run.update(run_attempt=2, status='queued', conclusion=None)
        with mock.patch.object(self.api, 'get', side_effect=get), mock.patch.object(self.api, 'pages', side_effect=pages), \
                mock.patch.object(self.api, 'mutate', side_effect=advance), \
                mock.patch.object(p, 'proof', side_effect=AssertionError('request step must not prove')):
            self.assertIn('Verified', n.refresh(self.api, p, target))
        self.assertEqual(calls[0], ('POST', p.route('actions/jobs/9001/rerun')))
        self.assertEqual([call for call in calls if call[0] == 'POST'], [calls[0]])

    def test_preflight_cut_by_its_step_timeout_leaves_tuple_unpoisoned(self):
        target = self.writer()
        prior = self.api.ready_jobs[(READY_RUN, 1)][0]
        # A step timeout fails preflight; the runner then skips the request step.
        prior.update(status='completed', conclusion='failure',
                     steps=[dict(name=n.PREFLIGHT_STEP, status='completed', conclusion='failure'),
                            dict(name=n.REQUEST_STEP, status='completed', conclusion='skipped')])
        current = dict(self.api.ready_run, id=READY_RUN + 1)
        self.api.ready_runs.append(current)
        self.api.refresh_writers.append(current)
        self.api.ready_jobs[(READY_RUN + 1, 1)] = [dict(prior, id=7778, status='in_progress', conclusion=None,
            steps=[dict(name=n.PREFLIGHT_STEP, status='in_progress', conclusion=None)])]
        def advance(method, path, payload):
            self.api.mutations.append((method, path, payload))
            self.api.native_run.update(run_attempt=2, status='queued', conclusion=None)
        with mock.patch.dict(os.environ, GITHUB_RUN_ID=str(READY_RUN + 1)), \
                mock.patch.object(self.api, 'mutate', side_effect=advance), mock.patch.object(n.time, 'sleep'):
            self.assertIn('Verified', self.write(target))
        self.assertEqual(self.api.mutations, [('POST', p.route('actions/jobs/9001/rerun'), {})])

    def test_claim_history_is_attempt_scoped_and_skips_runs_that_cannot_claim(self):
        target = self.writer()
        started = datetime.fromisoformat(self.api.native_run['created_at'].replace('Z', '+00:00'))
        self.api.native_run['run_started_at'] = self.api.native_run['created_at']
        pr_target = dict(self.api.ready_run, id=READY_RUN + 5, event='pull_request_target')
        self.api.refresh_writers.append(pr_target)
        self.api.ready_jobs[(READY_RUN + 5, 1)] = [dict(id=7790, name=n.claim_name(target), status='completed',
            conclusion='failure', steps=[dict(name=n.REQUEST_STEP, status='completed', conclusion='failure')])]
        self.assertTrue(n.preflight(self.api, p, target, False)[0])
        history = [route for route in self.api.reads if 'dependabot-auto-merge.yml/runs?created=' in route]
        bound = urllib.parse.urlencode({'created': '>=' + self.api.native_run['run_started_at']})
        self.assertTrue(history and all(route.endswith('runs?' + bound) for route in history), history)
        self.assertFalse(any(f'actions/runs/{READY_RUN + 5}/' in route for route in self.api.reads))
        # A rerun attempt starts later than its run: an older writer cannot claim it.
        self.api.native_run['run_started_at'] = (started + timedelta(seconds=5)).isoformat().replace('+00:00', 'Z')
        with self.assertRaisesRegex(p.Rejected, 'writer predates reporter attempt'):
            n.preflight(self.api, p, target, False)
        del self.api.native_run['run_started_at']
        with self.assertRaisesRegex(p.Rejected, 'authoritative start time'):
            n.preflight(self.api, p, target, False)
        self.assertFalse(self.api.mutations)

    def test_unknown_post_reads_once_sequence_and_durable_claim_blocks_next_writer(self):
        target = self.writer()
        with mock.patch.object(self.api, 'mutate', side_effect=TimeoutError('lost reply')) as mutation, mock.patch.object(n.time, 'sleep'):
            with self.assertRaisesRegex(p.Rejected, 'unconfirmed'): self.write(target)
            self.assertEqual(mutation.call_count, 1)
        prior = self.api.ready_jobs[(READY_RUN, 1)][0]
        prior.update(status='completed', conclusion='failure')
        prior['steps'][0].update(status='completed', conclusion='failure')
        current = dict(self.api.ready_run, id=READY_RUN + 1)
        self.api.ready_runs.append(current)
        self.api.refresh_writers.append(current)
        self.api.ready_jobs[(READY_RUN + 1, 1)] = [dict(prior, id=7778, status='in_progress')]
        with mock.patch.dict(os.environ, GITHUB_RUN_ID=str(READY_RUN + 1)), mock.patch.object(self.api, 'mutate') as mutation:
            with self.assertRaisesRegex(p.Rejected, 'prior refresh'): n.preflight(self.api, p, target, False)
            mutation.assert_not_called()

    def test_unstarted_earlier_claims_defer_preflight_but_contradictions_block(self):
        target = self.writer()
        current_started = datetime.fromisoformat(self.api.native_run['created_at'].replace('Z', '+00:00'))
        other = dict(self.api.ready_run, id=READY_RUN + 1, status='pending', created_at=(current_started + timedelta(seconds=1)).isoformat())
        self.api.refresh_writers.append(other)
        unstarted = dict(id=7780, name=n.claim_name(target), status='queued', conclusion=None, steps=[])
        self.api.ready_jobs[(READY_RUN + 1, 1)] = [unstarted]
        for status in sorted(n.NOT_STARTED):
            unstarted['status'] = status
            other['created_at'] = (current_started + timedelta(seconds=1)).isoformat()
            n.reject_prior_claim(self.api, p, target, self.api.native_run)
            other['created_at'] = (current_started - timedelta(seconds=1)).isoformat()
            with self.subTest(status=status), self.assertRaises(n.Deferred):
                n.reject_prior_claim(self.api, p, target, self.api.native_run)
        other['created_at'] = (current_started + timedelta(seconds=1)).isoformat()
        other.update(status='completed', conclusion='failure')
        with self.assertRaisesRegex(p.Rejected, 'ambiguous'):
            n.reject_prior_claim(self.api, p, target, self.api.native_run)
        self.assertFalse(self.api.mutations)

    def burst(self, target):
        started = datetime.fromisoformat(self.api.native_run['created_at'].replace('Z', '+00:00'))
        first = self.api.ready_jobs[(READY_RUN, 1)][0]
        first.update(started_at=(started + timedelta(seconds=2)).isoformat(),
                     steps=[dict(name=n.PREFLIGHT_STEP, status='in_progress', conclusion=None),
                            dict(name=n.REQUEST_STEP, status='pending', conclusion=None)])
        contender = dict(self.api.ready_run, id=READY_RUN + 1, status='pending',
                         created_at=(started + timedelta(seconds=1)).isoformat())
        self.api.ready_runs.append(contender)
        self.api.refresh_writers.append(contender)
        later = dict(id=7780, name=n.claim_name(target), status='pending', conclusion=None, steps=[])
        self.api.ready_jobs[(READY_RUN + 1, 1)] = [later]
        return started, first, contender, later

    def test_simultaneous_preplanned_wakes_defer_to_one_unpoisoned_request(self):
        target = self.writer()
        started, first, contender, later = self.burst(target)
        self.assertEqual(n.preflight(self.api, p, target, False)[0], False)
        self.assertFalse(self.api.mutations)
        # The deferring writer never entered its request step, so the next
        # serialized claim may still request this exact tuple once.
        first.update(status='completed', conclusion='success')
        first['steps'][0].update(status='completed', conclusion='success')
        first['steps'][1].update(status='completed', conclusion='skipped')
        contender['status'] = 'in_progress'
        later.update(status='in_progress', started_at=(started + timedelta(seconds=4)).isoformat(),
                     steps=[dict(name=n.PREFLIGHT_STEP, status='in_progress', conclusion=None),
                            dict(name=n.REQUEST_STEP, status='pending', conclusion=None)])
        def advance(method, path, payload):
            self.api.mutations.append((method, path, payload))
            self.api.native_run.update(run_attempt=2, status='queued', conclusion=None)
        with mock.patch.dict(os.environ, GITHUB_RUN_ID=str(READY_RUN + 1)):
            self.assertEqual(n.preflight(self.api, p, target, False)[0], True)
            later['steps'][0].update(status='completed', conclusion='success')
            later['steps'][1].update(status='in_progress')
            with mock.patch.object(self.api, 'mutate', side_effect=advance), mock.patch.object(n.time, 'sleep'):
                self.assertIn('Verified', n.refresh(self.api, p, target))
        self.assertEqual(self.api.mutations, [('POST', p.route('actions/jobs/9001/rerun'), {})])

    def test_executed_request_step_still_requires_operator_recovery(self):
        target = self.writer()
        started, first, contender, later = self.burst(target)
        # A writer that entered its request step may have POSTed before failing;
        # no later wake can erase that conservative interlock.
        first.update(status='completed', conclusion='failure')
        first['steps'][0].update(status='completed', conclusion='success')
        contender['status'] = 'in_progress'
        later.update(status='in_progress', started_at=(started + timedelta(seconds=4)).isoformat(),
                     steps=[dict(name=n.PREFLIGHT_STEP, status='in_progress', conclusion=None)])
        # Failed after a lost reply, or cut by its timeout mid-POST: either way
        # the request step executed and its outcome is not proof of no POST.
        for conclusion in ('failure', 'cancelled'):
            first['steps'][1].update(status='completed', conclusion=conclusion)
            with self.subTest(conclusion=conclusion), mock.patch.dict(os.environ, GITHUB_RUN_ID=str(READY_RUN + 1)):
                with self.assertRaisesRegex(p.Rejected, 'prior refresh'):
                    n.preflight(self.api, p, target, False)
        self.assertFalse(self.api.mutations)

    def test_preflight_cli_publishes_request_decision_and_rejection_requests_nothing(self):
        target = self.writer()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            for decision, expected in [((True, 'verified'), 'request=true\n'), ((False, 'Deferred: earlier claim'), 'request=false\n')]:
                with mock.patch.object(n, 'policy_module', return_value=p), mock.patch.object(p, 'GitHub', return_value=self.api), \
                        mock.patch.object(n.sys, 'argv', ['ready-policy', 'preflight']), \
                        mock.patch.dict(os.environ, REFRESH_TARGET=json.dumps(target), GITHUB_OUTPUT=str(output)), \
                        mock.patch.object(n, 'preflight', return_value=decision):
                    self.assertEqual(n.main(), 0)
                self.assertEqual(output.read_text(), expected)
                output.unlink()
            with mock.patch.object(n, 'policy_module', return_value=p), mock.patch.object(p, 'GitHub', return_value=self.api), \
                    mock.patch.object(n.sys, 'argv', ['ready-policy', 'preflight']), \
                    mock.patch.dict(os.environ, REFRESH_TARGET=json.dumps(target), GITHUB_OUTPUT=str(output)), \
                    mock.patch.object(n, 'preflight', side_effect=p.Rejected('prior refresh attempt exists')):
                self.assertEqual(n.main(), 1)
            self.assertFalse(output.exists())
        self.assertFalse(self.api.mutations)

    def test_lost_post_reply_with_confirmed_attempt_advance_is_not_retried(self):
        target = self.writer()
        def lost(*args):
            self.api.native_run.update(run_attempt=2, status='queued', conclusion=None)
            raise TimeoutError('reply lost after acceptance')
        with mock.patch.object(self.api, 'mutate', side_effect=lost) as mutation:
            self.assertIn('Verified', self.write(target))
            self.assertEqual(mutation.call_count, 1)

    def test_plan_and_writer_recheck_races_and_armed_bot(self):
        # The reporter or auto-merge request moving while the claim history is
        # read invalidates the plan without a second full proof.
        races = [lambda api: api.native_run.update(run_attempt=2, status='queued', conclusion=None),
                 lambda api: api.native_run.update(conclusion='success'),
                 lambda api: api.pr.update(auto_merge=dict(enabled_by=dict(p.BOT)))]
        for race in races:
            self.api = Transcript()
            target = self.writer()
            original = n.reject_prior_claim
            def racing(api, policy, claimed, reporter, race=race):
                original(api, policy, claimed, reporter)
                race(self.api)
            with self.subTest(race=race), mock.patch.object(n, 'reject_prior_claim', side_effect=racing):
                with self.assertRaisesRegex(p.Rejected, 'changed before'): n.preflight(self.api, p, target, False)
            self.assertFalse(self.api.mutations)
        self.api = Transcript()
        target = self.writer()
        self.api.pr['user'] = dict(p.BOT)
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        self.verdict(True)
        with mock.patch.object(n, 'refresh_plan', return_value=target):
            with self.assertRaisesRegex(p.Rejected, 'armed refresh only activates'): n.preflight(self.api, p, target, True)
        self.assertFalse(self.api.mutations)

    def test_snapshot_ref_workflow_event_job_source_and_run_guards(self):
        self.running()
        for key, value in [('GITHUB_REPOSITORY', 'foreign/repo'), ('GITHUB_REF', 'refs/heads/unsafe'),
                           ('GITHUB_WORKFLOW_REF', 'foreign'), ('GITHUB_EVENT_NAME', 'pull_request'),
                           ('GITHUB_JOB', 'bot-ready'), ('GITHUB_WORKFLOW_SHA', 'invalid'),
                           ('GITHUB_RUN_ID', str(NATIVE_RUN - 1)), ('GITHUB_RUN_ATTEMPT', '2')]:
            with self.subTest(key=key), self.assertRaises(p.Rejected):
                self.snapshot(overrides={key: value})
        self.assertFalse(self.api.mutations)

    def test_cli_false_verdict_fails_enforcement_and_api_error_emits_no_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            with mock.patch.object(n, 'policy_module', return_value=p), mock.patch.object(p, 'GitHub', return_value=self.api), \
                    mock.patch.object(n.sys, 'argv', ['ready-policy', 'snapshot', '--pr', str(NUMBER)]), \
                    mock.patch.dict(os.environ, GITHUB_OUTPUT=str(output)), \
                    mock.patch.object(n, 'snapshot', return_value=(False, 'missing full proof')):
                self.assertEqual(n.main(), 0)
            self.assertEqual(output.read_text(), 'ready=false\n')
            self.assertNotEqual(subprocess.run(['bash', '-c', 'test "$READY" = true'], env={**os.environ, 'READY':'false'}).returncode, 0)
            output.unlink()
            with mock.patch.object(n, 'policy_module', return_value=p), mock.patch.object(p, 'GitHub', return_value=self.api), \
                    mock.patch.object(n.sys, 'argv', ['ready-policy', 'snapshot', '--pr', str(NUMBER)]), \
                    mock.patch.dict(os.environ, GITHUB_OUTPUT=str(output)), \
                    mock.patch.object(n, 'snapshot', side_effect=OSError('API unavailable')):
                self.assertEqual(n.main(), 1)
            self.assertFalse(output.exists())
            self.assertFalse(self.api.mutations)

    def test_plan_cli_is_readonly_and_never_publishes_partial_or_untrusted_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            with mock.patch.object(n, 'policy_module', return_value=p), mock.patch.object(p, 'GitHub', return_value=self.api), \
                    mock.patch.object(n.sys, 'argv', ['ready-policy', 'plan']), \
                    mock.patch.dict(os.environ, PR_NUMBERS=json.dumps([NUMBER, NUMBER + 1]), GITHUB_OUTPUT=str(output)), \
                    mock.patch.object(n, 'refresh_plan', side_effect=[dict(pr=NUMBER), OSError('API unavailable')]):
                self.assertEqual(n.main(), 1)
            self.assertFalse(output.exists())
            with mock.patch.object(n, 'policy_module', return_value=p), mock.patch.object(p, 'GitHub') as api, \
                    mock.patch.object(n.sys, 'argv', ['ready-policy', 'plan']), \
                    mock.patch.dict(os.environ, GITHUB_REF='refs/heads/untrusted'):
                self.assertEqual(n.main(), 1)
                api.assert_not_called()
            self.assertFalse(self.api.mutations)

    def test_plan_isolates_one_prs_policy_rejection_from_the_others(self):
        # 2026-11-04 06:33: PR #71's obsolete reporter rejected the whole plan
        # job, so PR #73 was never planned. Only that PR is now withheld. A
        # recorded reporter cancellation or infrastructure failure is likewise
        # that PR's operator-recovery state, not an error of this planner's API.
        def obsolete(api):
            api.base = 'e' * 40
            api.source_blobs[f'contents/{n.REPORTER_PATH}?ref={BASE}'] = 'f' * 40
        def cancelled(api):
            for item in [api.native_run, api.native_job, api.native_check]:
                item['conclusion'] = 'cancelled'
        def evaluation_failed(api):
            api.native_job['steps'][1]['conclusion'] = 'failure'
        other = dict(pr=NUMBER + 1, head=HEAD, run=NATIVE_RUN + 7, attempt=1, job=9701)
        real = n.refresh_plan
        def plan(api, policy, number, enabled):
            return real(api, policy, number, enabled) if number == NUMBER else other
        for record, reason in [(obsolete, 'obsolete reporter definition/policy'),
                               (cancelled, 'reporter must be terminal success/failure; cancelled/unknown requires operator recovery'),
                               (evaluation_failed, 'reporter infrastructure/API/evaluation failure requires operator recovery')]:
            self.api = Transcript()
            self.verdict(False)
            record(self.api)
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'output'
                stderr = io.StringIO()
                with mock.patch.object(n, 'policy_module', return_value=p), mock.patch.object(p, 'GitHub', return_value=self.api), \
                        mock.patch.object(n.sys, 'argv', ['ready-policy', 'plan']), \
                        mock.patch.dict(os.environ, PR_NUMBERS=json.dumps([NUMBER, NUMBER + 1]), GITHUB_OUTPUT=str(output)), \
                        mock.patch.object(n, 'refresh_plan', side_effect=plan), contextlib.redirect_stderr(stderr):
                    self.assertEqual(n.main(), 0)
                self.assertEqual(output.read_text(), 'targets=' + json.dumps([other], separators=(',', ':')) +
                                 f'\nrejected=[{NUMBER}]\n')
                self.assertIn(f'PR #{NUMBER}: {reason}', stderr.getvalue())
                self.assertEqual(n.plan_targets(self.api, p, [NUMBER], True), ([], [NUMBER]))
                self.assertFalse(self.api.mutations)

    def test_coordinator_refuses_unreceipted_success_or_changed_failure_and_cancels(self):
        self.api.pr['auto_merge'] = dict(enabled_by=dict(p.BOT))
        self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertFalse(any(m[0] in {'POST','PATCH'} for m in self.api.mutations))
        self.api = Transcript()
        self.verdict(False)
        arm = p.arm_policy()
        binding = (NATIVE_RUN, 1, 9001, 9000)
        with mock.patch.object(p, 'arm_policy', return_value=arm), \
                mock.patch.object(arm, 'failure_barrier', side_effect=[binding, (NATIVE_RUN, 2, 9003, 9002)]):
            self.assertIn('blocked', p.coordinate(self.api, NUMBER, True))
        self.assertIsNone(self.api.pr['auto_merge'])
        self.assertEqual(sum('enablePullRequestAutoMerge' in str(m[1]) for m in self.api.mutations), 0)
        self.assertFalse(self.api.mutations)

    def test_reporter_notifications_are_exact_workflow_and_event(self):
        self.assertEqual(p.targets(self.api, 'workflow_run', dict(workflow_run=dict(id=NATIVE_RUN)))[0], [NUMBER])
        self.api.native_run['event'] = 'workflow_dispatch'
        with self.assertRaises(p.Rejected):
            p.targets(self.api, 'workflow_run', dict(workflow_run=dict(id=NATIVE_RUN)))

    def test_workflow_has_no_skipped_required_job_no_write_reporter_or_heavy_rerun(self):
        reporter = (ROOT / n.REPORTER_PATH).read_text()
        self.assertIn('name: Dependabot Merge Ready', reporter)
        self.assertNotIn('\n    if:', reporter)
        self.assertNotIn(': write', reporter)
        self.assertNotIn('workflow_dispatch:', reporter)
        self.assertNotIn('workflow_run:', reporter)
        self.assertIn('ref: ${{ github.workflow_sha }}', reporter)
        self.assertIn('run-name: \'Ready v1 pr:${{ github.event.pull_request.number }}', reporter)
        self.assertIn('head-repo:${{ github.event.pull_request.head.repo.id }}', reporter)
        self.assertNotIn('github.event.pull_request.title', reporter)
        self.assertNotIn('github.event.pull_request.body', reporter)
        coordinator = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        self.assertNotIn('checks: write', coordinator)
        self.assertNotIn('statuses: write', coordinator)
        self.assertIn('workflows: [CI, Dependabot Review Notice, Dependabot Ready]', coordinator)
        writer = coordinator.split('  ready-refresh:\n',1)[1].split('  bot-ready:\n',1)[0]
        self.assertIn('actions: write', writer)
        self.assertIn('needs: [inspect, ready-plan, bot-ready]', writer)
        self.assertNotIn('contents: write', writer)
        self.assertNotIn('pull-requests: write', writer)
        # Only the request step can POST; a skipped request step proves no POST.
        preflight, request = writer.index('name: ' + n.PREFLIGHT_STEP), writer.index('name: ' + n.REQUEST_STEP)
        self.assertLess(preflight, request)
        self.assertIn('id: preflight', writer[preflight:request])
        self.assertIn('dependabot-ready-policy.py preflight', writer[preflight:request])
        self.assertIn("if: steps.preflight.outputs.request == 'true'", writer[request:])
        self.assertIn('dependabot-ready-policy.py refresh', writer[request:])
        # Each step, checkout included, owns a budget inside the job timeout:
        # slow checkout or verification is cut before the request step (request
        # skipped), never inside or shortening the request step.
        checkout = writer.index('name: Checkout trusted coordinator only')
        self.assertLess(checkout, preflight)
        job_limit = int(re.search(r'^    timeout-minutes: ([0-9]+)$', writer, re.M)[1])
        limits = [int(re.search(r'^        timeout-minutes: ([0-9]+)$', section, re.M)[1])
                  for section in (writer[checkout:preflight], writer[preflight:request], writer[request:])]
        self.assertLess(sum(limits), job_limit)
        self.assertEqual(writer.count('REFRESH_TARGET: ${{ toJSON(matrix.target) }}'), 2)
        self.assertNotIn('DEPENDABOT_AUTO_MERGE_ENABLED', writer[request:])
        # A PR-isolated plan rejection still fails the planner, after targets.
        planner = coordinator.split('  ready-plan:\n', 1)[1].split('  ready-refresh:\n', 1)[0]
        self.assertIn('rejected: ${{ steps.plan.outputs.rejected }}', planner)
        report = planner.index('name: Report PR-isolated Ready plan rejections')
        self.assertLess(planner.index('dependabot-ready-policy.py plan'), report)
        self.assertIn("if: steps.plan.outputs.rejected != '[]'", planner[report:])
        self.assertIn('exit 1', planner[report:])
        self.assertIn("(needs.ready-plan.result == 'success' || (needs.ready-plan.result == 'failure' && "
                      "needs.ready-plan.outputs.rejected != '' && needs.ready-plan.outputs.rejected != '[]'))", writer)
        code = (ROOT / 'scripts/dependabot-ready-policy.py').read_text()
        self.assertEqual(code.count('api.mutate('), 1)
        self.assertIn('actions/jobs/{target[\'job\']}/rerun', code)
        self.assertNotIn('api.mutate("PATCH"', code)
        self.assertNotIn('route("check-runs")', code)


if __name__ == '__main__': unittest.main()
