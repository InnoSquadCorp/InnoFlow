"""Offline lifecycle proofs for post-enable native Ready arm receipts."""
import copy
from datetime import datetime, timedelta
import os
import unittest
from unittest import mock

from test_dependabot_merge_policy import (
    BASE, HEAD, NUMBER, RUN, READY_RUN, NATIVE_RUN, TRUSTED, Transcript, p,
)

n = p.ready_policy()
a = p.arm_policy()
ACTOR = dict(__typename='Bot', login='github-actions', databaseId=41898282)


class ArmTranscript(Transcript):
    def __init__(self):
        super().__init__()
        self.native_history = {}
        self.request_reads = 0
        self.enable_outcome = 'success'
        self.disable_outcome = 'success'
        self.after_enable = None
        self.lifecycle = 0
        self.rerun_outcome = 'success'
        self.rerun_advances = 1
        self.comparisons = {}
        self.request_graph = dict(repository=dict(databaseId=self.repo['id'], nameWithOwner=p.REPOSITORY,
            pullRequest=dict(id=self.pr['node_id'], headRefOid=HEAD, autoMergeRequest=None,
                             timelineItems=dict(nodes=[]))))
        self.verdict(False)

    def verdict(self, ready):
        result = 'success' if ready else 'failure'
        for item in (self.native_run, self.native_job, self.native_check):
            item.update(status='completed', conclusion=result)
        for step in self.native_job['steps']:
            step.update(status='completed', conclusion='success')
        self.native_job['steps'][-1]['conclusion'] = result

    def enable(self):
        self.lifecycle += 1
        self.pr['auto_merge'] = dict(enabled_by=dict(login='github-actions[bot]', id=ACTOR['databaseId'], type='Bot'))
        timestamp = self.native_run['created_at']
        graph = self.request_graph['repository']['pullRequest']
        graph['autoMergeRequest'] = dict(enabledAt=timestamp, mergeMethod='SQUASH', enabledBy=copy.deepcopy(ACTOR))
        graph['timelineItems']['nodes'] = [dict(__typename='AutoMergeEnabledEvent', id=f'event-{self.lifecycle}',
                                              createdAt=timestamp, actor=copy.deepcopy(ACTOR))]

    def graphql(self, query, variables):
        if 'enablePullRequestAutoMerge' in query:
            self.mutations.append(('graphql', query, copy.deepcopy(variables)))
            if self.enable_outcome != 'raise_without_apply':
                self.enable()
                if self.after_enable is not None:
                    self.after_enable(self)
            if self.enable_outcome != 'success':
                raise OSError('enable response lost')
            return {}
        if 'disablePullRequestAutoMerge' in query:
            self.mutations.append(('graphql', query, copy.deepcopy(variables)))
            if self.disable_outcome != 'raise_without_apply':
                self.pr['auto_merge'] = None
                self.request_graph['repository']['pullRequest']['autoMergeRequest'] = None
            if self.disable_outcome != 'success':
                raise OSError('disable response lost')
            return {}
        if 'timelineItems' in query:
            self.request_reads += 1
            if variables != dict(number=NUMBER):
                raise AssertionError('Unexpected request identity variables')
            return copy.deepcopy(self.request_graph)
        return super().graphql(query, variables)

    def get(self, route):
        if route in self.comparisons:
            self.reads.append(route)
            return copy.deepcopy(self.comparisons[route])
        prefix = p.route(f'actions/runs/{NATIVE_RUN}/attempts/')
        if route.startswith(prefix) and route[len(prefix):].isdigit():
            self.reads.append(route)
            return copy.deepcopy(self.native_history[int(route[len(prefix):])])
        return super().get(route)

    def publish_receipt(self, name, background=False):
        """Expose the coordinator's actual completed jobs as GitHub metadata."""
        self.receipt_run = self.ready_run
        if background:
            self.receipt_run = copy.deepcopy(self.ready_run)
            self.receipt_run.update(id=970, event='workflow_run', head_sha=BASE, head_branch='main',
                                    check_suite_id=801, pull_requests=[])
            self.ready_runs.append(self.receipt_run)
        self.receipt_job = self.coordinator_job(f'bot-ready ({NUMBER})', 8101, 8100,
            [a.GATE_STEP, name])
        self.inspect_job = self.coordinator_job('inspect', 8201, 8200,
            [p.COORDINATOR_SOURCE_STEP + BASE])
        self.ready_jobs[(self.receipt_run['id'], 1)] = [self.inspect_job, self.receipt_job]
        self.refresh_writers = [self.receipt_run]
        self.receipt_run['created_at'] = self.native_run['created_at']

    def coordinator_job(self, name, identifier, check_id, steps):
        run = self.receipt_run
        job = dict(id=identifier, name=name, run_id=run['id'], run_attempt=1, head_sha=run['head_sha'],
                   status='completed', conclusion='success',
                   check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                   steps=[dict(name=step, status='completed', conclusion='success') for step in steps])
        self.checks.append(dict(id=check_id, name=name, app=dict(id=p.APP), head_sha=run['head_sha'],
            check_suite=dict(id=run['check_suite_id']), status='completed', conclusion='success',
            details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{run["id"]}/job/{identifier}'))
        return job

    def pages(self, route, key=None):
        if route.startswith(p.route('actions/workflows/dependabot-auto-merge.yml/runs?event=')):
            self.reads.append(route)
            return copy.deepcopy([run for run in self.ready_runs if run['event'] == 'pull_request_target'])
        return super().pages(route, key)

    def mutate(self, method, route, payload):
        if route == p.route('actions/jobs/9001/rerun'):
            self.mutations.append((method, route, copy.deepcopy(payload)))
            if self.rerun_outcome != 'raise_without_apply':
                for _ in range(self.rerun_advances):
                    self.advance(status='queued', materialize=False)
            if self.rerun_outcome != 'success':
                raise OSError('rerun response lost')
            return None
        return super().mutate(method, route, payload)

    def advance(self, status='in_progress', conclusion=None, materialize=True):
        previous = copy.deepcopy(self.native_run)
        self.native_history[previous['run_attempt']] = previous
        attempt = previous['run_attempt'] + 1
        self.native_run.update(run_attempt=attempt, status=status, conclusion=conclusion)
        self.native_job = copy.deepcopy(self.native_job)
        self.native_check = copy.deepcopy(self.native_check)
        self.native_job.update(id=9001 + 100 * attempt, status=status, conclusion=conclusion,
            check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{9000 + 100 * attempt}')
        self.native_check.update(id=9000 + 100 * attempt, status=status, conclusion=conclusion,
            details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{NATIVE_RUN}/job/{self.native_job["id"]}')
        self.native_jobs[(NATIVE_RUN, attempt)] = [self.native_job] if materialize else []
        if materialize:
            self.checks.append(self.native_check)
        for step in self.native_job['steps']:
            step.update(status='completed', conclusion='success')
        if status != 'completed':
            self.native_job['steps'][-1].update(status='queued', conclusion=None)
        else:
            self.native_job['steps'][-1]['conclusion'] = conclusion


class DependabotArmPolicyTests(unittest.TestCase):
    def setUp(self):
        self.api = ArmTranscript()
        env = dict(TRUSTED, GITHUB_JOB='bot-ready', GITHUB_WORKFLOW_SHA=BASE)
        patch = mock.patch.dict(os.environ, env, clear=True)
        patch.start()
        self.addCleanup(patch.stop)

    def arm(self, api=None):
        api = self.api if api is None else api
        receipts = []
        result = p.coordinate(api, NUMBER, True, receipt_sink=receipts.append)
        self.assertIn('post-enable receipt', result)
        self.assertEqual(len(receipts), 1)
        return receipts[0]

    def activate(self, status='in_progress', conclusion=None, materialize=True):
        receipt = self.arm()
        self.api.publish_receipt(receipt)
        self.api.advance(status, conclusion, materialize)
        return receipt

    def assert_blocked(self, api=None):
        api = self.api if api is None else api
        before = copy.deepcopy(api.mutations)
        verdict, reason = n.desired(api, p, NUMBER, True)
        self.assertFalse(verdict, reason)
        self.assertEqual(api.mutations, before, 'Readonly reporter cannot repair/cancel requests')
        return reason

    def test_failure_enable_postproof_receipt_and_exact_next_activation(self):
        self.assert_blocked()
        self.assertEqual(a.failure_barrier(self.api, p, n, NUMBER, HEAD), (NATIVE_RUN, 1, 9001, 9000))
        receipt = self.arm()
        self.assert_blocked()  # An enabled request alone is not a receipt.
        self.api.publish_receipt(receipt)
        self.assertFalse(n.controlled_verdict(p, self.api.native_run, self.api.native_job, self.api.native_check))
        target = n.refresh_plan(self.api, p, NUMBER, True)
        self.assertEqual(target, dict(pr=NUMBER, head=HEAD, run=NATIVE_RUN, attempt=1, job=9001))
        self.api.advance()
        self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])
        self.api.verdict(True)
        self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])
        self.assertEqual(n.require_success(self.api, p, NUMBER, HEAD), (NATIVE_RUN, 2, 9200))
        self.assertEqual(len(self.api.mutations), 1)
        query, variables = self.api.mutations[0][1:]
        self.assertIn('expectedHeadOid:$head,mergeMethod:SQUASH', query)
        self.assertEqual(variables, dict(id='PR_node', head=HEAD))


    def test_authenticated_receipt_is_readonly_and_does_not_recurse_into_full_proof(self):
        self.activate()
        expected = p.proof(self.api, NUMBER)
        self.api.reads.clear()
        before = copy.deepcopy(self.api.mutations)
        receipt = a.authenticated_receipt(self.api, p, n, NUMBER, self.api.pr, expected_proof=expected)
        self.assertEqual(receipt['barrier'], (NATIVE_RUN, 1, 9001, 9000))
        self.assertEqual(receipt['proof'], a.proof_digest(expected))
        self.assertFalse(any('/actions/workflows/ci.yml' in path for path in self.api.reads))
        self.assertEqual(self.api.mutations, before)

    def test_new_enable_requires_controlled_failure_and_never_success_or_pending(self):
        for state in ('success', 'in_progress', 'queued', 'cancelled', 'infra-failure'):
            with self.subTest(state=state):
                api = ArmTranscript()
                if state == 'success':
                    api.verdict(True)
                elif state == 'infra-failure':
                    api.native_job['steps'][0]['conclusion'] = 'failure'
                else:
                    status = 'completed' if state == 'cancelled' else state
                    for item in (api.native_run, api.native_job, api.native_check):
                        item.update(status=status, conclusion='cancelled' if state == 'cancelled' else None)
                receipts = []
                result = p.coordinate(api, NUMBER, True, receipt_sink=receipts.append)
                self.assertTrue(result.startswith('blocked:'), result)
                self.assertEqual(receipts, [])
                self.assertEqual(api.mutations, [])

    def test_unknown_enable_outcome_is_read_back_once_without_retry(self):
        for outcome in ('raise_after_apply', 'raise_without_apply'):
            with self.subTest(outcome=outcome):
                api = ArmTranscript()
                api.enable_outcome = outcome
                receipts = []
                result = p.coordinate(api, NUMBER, True, receipt_sink=receipts.append)
                self.assertEqual(len(api.mutations), 1)
                self.assertIn('enablePullRequestAutoMerge', api.mutations[0][1])
                if outcome == 'raise_after_apply':
                    self.assertIn('post-enable receipt', result)
                    self.assertEqual(len(receipts), 1)
                else:
                    self.assertIn('native enable outcome not confirmed', result)
                    self.assertEqual(receipts, [])

    def test_distinct_native_request_and_event_timestamps_are_bound_not_assumed_equal(self):
        def delayed_event(api):
            event = api.request_graph['repository']['pullRequest']['timelineItems']['nodes'][0]
            original = datetime.fromisoformat(event['createdAt'].replace('Z', '+00:00'))
            event['createdAt'] = (original + timedelta(seconds=1)).isoformat().replace('+00:00', 'Z')
        self.api.after_enable = delayed_event
        receipts = []
        self.assertIn('armed', p.coordinate(self.api, NUMBER, True, receipt_sink=receipts.append))
        self.api.publish_receipt(receipts[0])
        self.api.advance()
        verdict, reason = n.desired(self.api, p, NUMBER, True)
        self.assertTrue(verdict, reason)
        delayed_event(self.api)  # Changing either timestamp invalidates the same receipt.
        self.assert_blocked()

    def test_post_enable_proof_failure_cancels_once_and_cannot_publish_receipt(self):
        changes = [
            ('CI failed', lambda api: api.run.update(conclusion='failure')),
            ('main advanced', lambda api: setattr(api, 'base', 'd' * 40)),
            ('head changed', lambda api: api.pr['head'].update(sha='d' * 40)),
            ('review blocked', lambda api: api.review_list.append(dict(id=1, user=dict(id=3), state='PENDING'))),
            ('barrier became success', lambda api: api.verdict(True)),
        ]
        for label, change in changes:
            with self.subTest(change=label):
                api = ArmTranscript()
                api.after_enable = change
                receipts = []
                result = p.coordinate(api, NUMBER, True, receipt_sink=receipts.append)
                self.assertTrue(result.startswith('blocked:'), result)
                self.assertEqual(receipts, [])
                self.assertIsNone(api.pr['auto_merge'])
                self.assertEqual(len(api.mutations), 2)
                self.assertIn('enablePullRequestAutoMerge', api.mutations[0][1])
                self.assertIn('disablePullRequestAutoMerge', api.mutations[1][1])

    def test_unknown_disable_outcome_is_never_retried(self):
        for outcome in ('raise_after_apply', 'raise_without_apply'):
            with self.subTest(outcome=outcome):
                api = ArmTranscript()
                api.after_enable = lambda api: api.run.update(conclusion='failure')
                api.disable_outcome = outcome
                receipts = []
                if outcome == 'raise_after_apply':
                    self.assertIn('blocked:', p.coordinate(api, NUMBER, True, receipt_sink=receipts.append))
                else:
                    with self.assertRaisesRegex(p.Rejected, 'cancellation unconfirmed'):
                        p.coordinate(api, NUMBER, True, receipt_sink=receipts.append)
                self.assertEqual(receipts, [])
                self.assertEqual(len(api.mutations), 2)
                self.assertIn('disablePullRequestAutoMerge', api.mutations[-1][1])

    def test_only_exact_next_attempt_can_use_a_receipt(self):
        for predecessor in ('in_progress', 'success', 'failure'):
            with self.subTest(predecessor=predecessor):
                self.api = ArmTranscript()
                self.activate()
                if predecessor != 'in_progress':
                    self.api.verdict(predecessor == 'success')
                self.api.advance()
                self.assert_blocked()
        self.api = ArmTranscript()
        receipt = self.arm()
        self.api.publish_receipt(receipt)
        self.api.native_run.update(id=NATIVE_RUN + 1, run_number=41)
        self.api.native_jobs[(NATIVE_RUN + 1, 1)] = [self.api.native_job]
        self.api.native_check['details_url'] = self.api.native_check['details_url'].replace(
            f'/runs/{NATIVE_RUN}/', f'/runs/{NATIVE_RUN + 1}/')
        self.assertIn('no trusted post-enable receipt', self.assert_blocked())

    def test_cancellation_or_same_second_rearming_invalidates_receipt(self):
        self.activate()
        prior = a.request_identity(self.api, p, NUMBER, self.api.pr)
        self.api.enable()  # Same enabledAt, different GitHub timeline node ID.
        self.assertNotEqual(a.request_identity(self.api, p, NUMBER, self.api.pr), prior)
        self.assert_blocked()
        self.api.pr['auto_merge'] = None
        self.assert_blocked()
        self.api = ArmTranscript()
        self.activate(status='completed', conclusion='cancelled')
        self.assert_blocked()

    def test_request_identity_requires_exact_actor_method_repository_head_and_event(self):
        changes = [
            ('repository ID', lambda data: data.update(databaseId=101)),
            ('repository ID type', lambda data: data.update(databaseId=100.0)),
            ('repository name', lambda data: data.update(nameWithOwner='foreign/repo')),
            ('PR node', lambda data: data['pullRequest'].update(id='other')),
            ('head', lambda data: data['pullRequest'].update(headRefOid=BASE)),
            ('request absent', lambda data: data['pullRequest'].update(autoMergeRequest=None)),
            ('merge method', lambda data: data['pullRequest']['autoMergeRequest'].update(mergeMethod='MERGE')),
            ('REST actor spelling', lambda data: data['pullRequest']['autoMergeRequest']['enabledBy'].update(login='github-actions[bot]')),
            ('actor login', lambda data: data['pullRequest']['autoMergeRequest']['enabledBy'].update(login='dependabot[bot]')),
            ('actor id', lambda data: data['pullRequest']['autoMergeRequest']['enabledBy'].update(databaseId=1)),
            ('actor id type', lambda data: data['pullRequest']['autoMergeRequest']['enabledBy'].update(databaseId='41898282')),
            ('actor type', lambda data: data['pullRequest']['autoMergeRequest']['enabledBy'].update(__typename='User')),
            ('missing timestamp', lambda data: data['pullRequest']['autoMergeRequest'].pop('enabledAt')),
            ('naive timestamp', lambda data: data['pullRequest']['autoMergeRequest'].update(enabledAt='2026-10-13T00:00:00')),
            ('malformed timestamp', lambda data: data['pullRequest']['autoMergeRequest'].update(enabledAt='bad')),
            ('missing event', lambda data: data['pullRequest']['timelineItems'].update(nodes=[])),
            ('multiple events', lambda data: data['pullRequest']['timelineItems']['nodes'].append(
                copy.deepcopy(data['pullRequest']['timelineItems']['nodes'][0]))),
            ('disabled event', lambda data: data['pullRequest']['timelineItems']['nodes'][0].update(__typename='AutoMergeDisabledEvent')),
            ('event timestamp', lambda data: data['pullRequest']['timelineItems']['nodes'][0].update(createdAt='other')),
            ('event actor', lambda data: data['pullRequest']['timelineItems']['nodes'][0]['actor'].update(login='other')),
            ('missing event ID', lambda data: data['pullRequest']['timelineItems']['nodes'][0].pop('id')),
        ]
        for label, change in changes:
            with self.subTest(change=label):
                api = ArmTranscript()
                api.enable()
                change(api.request_graph['repository'])
                with self.assertRaises(p.Rejected):
                    a.request_identity(api, p, NUMBER, api.pr)
                self.assertEqual(api.mutations, [])

    def test_current_head_base_review_and_ci_remain_mandatory_after_arming(self):
        changes = [
            ('head', lambda api: api.pr['head'].update(sha='d' * 40)),
            ('main', lambda api: setattr(api, 'base', 'd' * 40)),
            ('base', lambda api: api.pr['base'].update(sha='d' * 40)),
            ('CI failed', lambda api: api.run.update(conclusion='failure')),
            ('CI provenance', lambda api: api.run.update(event='push')),
            ('CI attempt', lambda api: api.run.update(run_attempt=2)),
            ('review', lambda api: api.review_list.append(dict(id=1, user=dict(id=3), state='CHANGES_REQUESTED'))),
            ('thread', lambda api: api.threads.append(dict(isResolved=False))),
        ]
        for label, change in changes:
            with self.subTest(change=label):
                self.api = ArmTranscript()
                self.activate()
                change(self.api)
                self.assert_blocked()

    def test_receipt_is_bound_to_exact_failure_tuple_and_current_proof(self):
        for field, value in [('head', BASE), ('base', HEAD), ('merge', HEAD),
                             ('run', RUN + 1), ('attempt', 2), ('node', 'other')]:
            with self.subTest(proof_field=field):
                self.api = ArmTranscript()
                self.activate()
                expected = p.proof(self.api, NUMBER)
                expected[field] = value
                with self.assertRaisesRegex(p.Rejected, 'no trusted post-enable receipt'):
                    a.authenticated_receipt(self.api, p, n, NUMBER, self.api.pr, expected_proof=expected)
        for index in range(4):
            with self.subTest(barrier_component=index):
                self.api = ArmTranscript()
                receipt = self.activate()
                barrier = [NATIVE_RUN, 1, 9001, 9000]
                altered = barrier.copy()
                altered[index] += 1
                self.api.receipt_job['steps'][-1]['name'] = receipt.replace(
                    'ready:' + ':'.join(map(str, barrier)), 'ready:' + ':'.join(map(str, altered)))
                self.assert_blocked()

    def test_queued_no_job_exception_is_only_for_authorized_next_attempt(self):
        for status in ('queued', 'pending', 'waiting', 'requested'):
            with self.subTest(status=status):
                self.api = ArmTranscript()
                self.activate(status=status, materialize=False)
                ids = n.verified_check_ids(self.api, p, NUMBER, HEAD)
                self.assertEqual(ids, {9000})
                self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])
                self.api.checks.append(dict(self.api.native_check, id=9999))
                with self.assertRaisesRegex(p.Rejected, 'unassociated/legacy Ready check'):
                    p.proof(self.api, NUMBER)
        self.api = ArmTranscript()
        self.arm()
        self.api.advance(status='queued', materialize=False)
        self.assert_blocked()  # No published receipt.
        self.api = ArmTranscript()
        self.activate(status='queued', materialize=False)
        self.api.enable()
        self.assert_blocked()  # A queued attempt cannot inherit a rearmed request.

    def test_receipt_requires_trusted_successful_inspect_and_final_bot_job(self):
        changes = [
            ('writer workflow', lambda api: api.receipt_run.update(workflow_id=12)),
            ('writer source path', lambda api: api.receipt_run.update(path='.github/workflows/other.yml')),
            ('writer head', lambda api: api.receipt_run.update(head_sha=BASE)),
            ('writer PR', lambda api: api.receipt_run['pull_requests'][0].update(number=NUMBER + 1)),
            ('writer repository', lambda api: api.receipt_run.update(repository=dict(id=101))),
            ('missing inspect', lambda api: api.ready_jobs[(READY_RUN, 1)].remove(api.inspect_job)),
            ('inspect failed', lambda api: api.inspect_job.update(conclusion='failure')),
            ('bot failed', lambda api: api.receipt_job.update(conclusion='failure')),
            ('receipt step failed', lambda api: api.receipt_job['steps'][-1].update(conclusion='failure')),
            ('receipt before gate', lambda api: api.receipt_job['steps'].reverse()),
            ('inspect source mismatch', lambda api: api.inspect_job['steps'][0].update(name=p.COORDINATOR_SOURCE_STEP + HEAD)),
            ('receipt source untrusted', lambda api: api.receipt_job['steps'][-1].update(
                name=api.receipt_job['steps'][-1]['name'].replace('source:' + BASE, 'source:' + HEAD))),
        ]
        for label, change in changes:
            with self.subTest(change=label):
                self.api = ArmTranscript()
                self.activate()
                change(self.api)
                with self.assertRaises(p.Rejected):
                    a.authenticated_receipt(self.api, p, n, NUMBER, self.api.pr)
        for job_id in (8100, 8200):
            for field in ('app', 'suite', 'head', 'job'):
                with self.subTest(check=job_id, field=field):
                    self.api = ArmTranscript()
                    self.activate()
                    check = next(check for check in self.api.checks if check['id'] == job_id)
                    if field == 'app':
                        check['app']['id'] = 123
                    elif field == 'suite':
                        check['check_suite']['id'] = 123
                    elif field == 'head':
                        check['head_sha'] = BASE
                    else:
                        check['details_url'] += '1'
                    with self.assertRaises(p.Rejected):
                        a.authenticated_receipt(self.api, p, n, NUMBER, self.api.pr)

    def prepare_refresh(self):
        receipt = self.arm()
        self.api.publish_receipt(receipt, background=True)
        target = n.refresh_plan(self.api, p, NUMBER, True)
        claim = dict(id=8301, name=n.claim_name(target), status='in_progress', conclusion=None,
                     started_at=self.api.native_run['created_at'],
                     steps=[dict(name=n.REQUEST_STEP, status='in_progress', conclusion=None)])
        self.api.ready_jobs[(970, 1)].append(claim)
        os.environ.update(GITHUB_RUN_ID='970', GITHUB_EVENT_NAME='workflow_run', GITHUB_JOB='ready-refresh')
        return target

    def test_armed_refresh_requires_same_writer_receipt_and_confirms_single_rerun(self):
        target = self.prepare_refresh()
        result = n.refresh(self.api, p, target, True)
        self.assertIn('Verified native reporter rerun requested', result)
        reruns = [mutation for mutation in self.api.mutations if mutation[0] == 'POST']
        self.assertEqual(reruns, [('POST', p.route('actions/jobs/9001/rerun'), {})])
        self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])

    def test_refresh_unknown_write_never_retries(self):
        for outcome in ('raise_after_apply', 'raise_without_apply'):
            with self.subTest(outcome=outcome):
                self.api = ArmTranscript()
                os.environ.update(GITHUB_JOB='bot-ready', GITHUB_RUN_ID=str(READY_RUN), GITHUB_EVENT_NAME='pull_request_target')
                target = self.prepare_refresh()
                self.api.rerun_outcome = outcome
                with mock.patch.object(n.time, 'sleep'):
                    if outcome == 'raise_after_apply':
                        self.assertIn('Verified native reporter rerun requested', n.refresh(self.api, p, target, True))
                    else:
                        with self.assertRaisesRegex(p.Rejected, 'refresh outcome unconfirmed; no retry'):
                            n.refresh(self.api, p, target, True)
                self.assertEqual(len([mutation for mutation in self.api.mutations if mutation[0] == 'POST']), 1)



    def test_receipt_jobs_are_bound_to_writer_run_attempt_and_head(self):
        for job_name in ('receipt_job', 'inspect_job'):
            for field, value in [('run_id', 99999), ('run_attempt', 99), ('head_sha', BASE)]:
                with self.subTest(job=job_name, field=field):
                    self.api = ArmTranscript()
                    self.activate()
                    getattr(self.api, job_name)[field] = value
                    with self.assertRaises(p.Rejected):
                        a.authenticated_receipt(self.api, p, n, NUMBER, self.api.pr)

    def test_refresh_cannot_borrow_receipt_from_a_different_writer(self):
        target = self.prepare_refresh()
        other = copy.deepcopy(self.api.receipt_run)
        other.update(id=971, check_suite_id=802)
        self.api.ready_runs.append(other)
        self.api.refresh_writers.append(other)
        self.api.ready_jobs[(971, 1)] = [copy.deepcopy(self.api.ready_jobs[(970, 1)][-1])]
        self.api.ready_jobs[(970, 1)].pop()  # Only the new writer owns a refresh claim.
        os.environ['GITHUB_RUN_ID'] = '971'
        with self.assertRaisesRegex(p.Rejected, 'no trusted post-enable receipt'):
            n.refresh(self.api, p, target, True)
        self.assertFalse(any(mutation[0] == 'POST' for mutation in self.api.mutations))



    def test_receipt_is_final_executable_step_with_only_fixed_cleanup_allowed(self):
        allowed = [[], ['Complete job'], ['Post Checkout trusted coordinator only'],
                   ['Post Checkout trusted coordinator only', 'Complete job']]
        denied = [['Run another command'], ['Post untrusted action'],
                  ['Complete job', 'Post Checkout trusted coordinator only'],
                  ['Post Checkout trusted coordinator only', 'Run another command', 'Complete job']]
        for names in allowed + denied:
            with self.subTest(suffix=names):
                self.api = ArmTranscript()
                self.activate()
                self.api.receipt_job['steps'].extend(
                    dict(name=name, status='completed', conclusion='success') for name in names)
                if names in allowed:
                    a.authenticated_receipt(self.api, p, n, NUMBER, self.api.pr)
                else:
                    with self.assertRaisesRegex(p.Rejected, 'final executable step'):
                        a.authenticated_receipt(self.api, p, n, NUMBER, self.api.pr)

    def test_writer_context_and_source_must_be_trusted_before_any_enable(self):
        for changes in [dict(GITHUB_JOB='ready-refresh'), dict(GITHUB_WORKFLOW_SHA=''),
                        dict(GITHUB_WORKFLOW_SHA='invalid'), dict(GITHUB_WORKFLOW_SHA=HEAD)]:
            with self.subTest(environment=changes), mock.patch.dict(os.environ, changes):
                api = ArmTranscript()
                receipts = []
                self.assertTrue(p.coordinate(api, NUMBER, True, receipt_sink=receipts.append).startswith('blocked:'))
                self.assertEqual(api.mutations, [])
                self.assertEqual(receipts, [])
        ancestor = 'e' * 40
        paths = [n.REPORTER_PATH, p.COORDINATOR_PATH, 'scripts/dependabot-ready-policy.py',
                 'scripts/dependabot-merge-policy.py', 'scripts/dependabot-arm-policy.py',
                 'scripts/ci-metadata-policy.py']
        for path in paths:
            with self.subTest(obsolete_definition=path), mock.patch.dict(os.environ, GITHUB_WORKFLOW_SHA=ancestor):
                api = ArmTranscript()
                api.comparisons[p.route(f'compare/{ancestor}...{BASE}')] = dict(
                    status='ahead', merge_base_commit=dict(sha=ancestor))
                api.source_blobs[f'contents/{path}?ref={ancestor}'] = 'f' * 40
                receipts = []
                result = p.coordinate(api, NUMBER, True, receipt_sink=receipts.append)
                self.assertIn('obsolete reporter definition/policy', result)
                self.assertEqual(api.mutations, [])
                self.assertEqual(receipts, [])



    def bind_native_title(self):
        title = (f'Ready v1 pr:{NUMBER} head:{HEAD} head-repo:100 base-repo:100 '
                 f'base:main source:{BASE}')
        self.api.native_run['display_title'] = title
        self.api.native_job['steps'][1]['name'] = n.SOURCE_STEP + BASE + ' for ' + title.rsplit(' source:', 1)[0]

    def queued_bound_job(self):
        self.bind_native_title()
        self.activate(status='queued', materialize=False)
        self.api.native_job['steps'] = []
        self.api.native_jobs[(NATIVE_RUN, 2)] = [self.api.native_job]
        self.api.checks.append(self.api.native_check)

    def test_bound_activation_moves_from_no_job_through_empty_steps_to_running(self):
        self.bind_native_title()
        self.activate(status='queued', materialize=False)
        self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])
        self.api.native_job['steps'] = []
        self.api.native_jobs[(NATIVE_RUN, 2)] = [self.api.native_job]
        self.api.checks.append(self.api.native_check)
        self.assertEqual(n.verified_check_ids(self.api, p, NUMBER, HEAD), {9000, 9200})
        self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])
        before = copy.deepcopy(self.api.mutations)
        self.assertIn('authorized native activation', p.coordinate(self.api, NUMBER, True))
        self.assertEqual(self.api.mutations, before)
        for item in (self.api.native_run, self.api.native_job, self.api.native_check):
            item.update(status='in_progress', conclusion=None)
        old_steps = self.api.native_jobs[(NATIVE_RUN, 1)][0]['steps']
        self.api.native_job['steps'] = copy.deepcopy(old_steps)
        self.api.native_job['steps'][-1].update(status='queued', conclusion=None)
        self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])
        self.api.verdict(True)
        self.assertTrue(n.desired(self.api, p, NUMBER, True)[0])

    def test_empty_step_binding_exception_rejects_wrong_source_or_malformed_execution(self):
        changes = [
            ('wrong source', lambda api: api.native_run.update(display_title=
                api.native_run['display_title'].replace('source:' + BASE, 'source:' + HEAD))),
            ('missing steps', lambda api: api.native_job.pop('steps')),
            ('null steps', lambda api: api.native_job.update(steps=None)),
            ('wrong steps type', lambda api: api.native_job.update(steps={})),
            ('run has conclusion', lambda api: api.native_run.update(conclusion='failure')),
            ('unknown step', lambda api: api.native_job.update(steps=[dict(name='Unexpected execution')])),
            ('wrong source step', lambda api: api.native_job.update(steps=[dict(name=n.SOURCE_STEP + HEAD)])),
            ('job started without steps', lambda api: api.native_job.update(status='in_progress')),
            ('check started without steps', lambda api: api.native_check.update(status='in_progress')),
            ('job has conclusion', lambda api: api.native_job.update(conclusion='success')),
            ('check has conclusion', lambda api: api.native_check.update(conclusion='success')),
            ('run cancelled', lambda api: api.native_run.update(status='completed', conclusion='cancelled')),
            ('rearm', lambda api: api.enable()),
            ('missing receipt', lambda api: api.refresh_writers.clear()),
            ('orphan check', lambda api: api.checks.append(dict(api.native_check, id=9999))),
        ]
        for label, change in changes:
            with self.subTest(change=label):
                self.api = ArmTranscript()
                self.queued_bound_job()
                change(self.api)
                self.assert_blocked()



    def test_refresh_readback_must_be_exactly_one_new_attempt(self):
        target = self.prepare_refresh()
        self.api.rerun_advances = 2
        with self.assertRaises(p.Rejected):
            n.refresh(self.api, p, target, True)
        self.assertEqual(self.api.native_run['run_attempt'], 3)
        self.assertEqual(len([mutation for mutation in self.api.mutations if mutation[0] == 'POST']), 1)
        self.assert_blocked()


if __name__ == '__main__':
    unittest.main()
