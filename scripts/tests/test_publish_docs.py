"""Offline source/provenance transcripts for the trusted Pages publisher."""
import copy
import importlib.util
import io
from pathlib import Path
import re
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('publish_docs', ROOT / 'scripts/publish-docs.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
HEAD, OLD = 'a' * 40, 'b' * 40
RUN, ATTEMPT = 91, 2


class Transcript:
    def __init__(self, name='CI', event='push', branch='main'):
        self.repo = dict(id=100, full_name=p.REPOSITORY, default_branch='main')
        self.run = dict(id=RUN, run_attempt=ATTEMPT, name=name, path=p.WORKFLOWS[name],
                        workflow_id=10, check_suite_id=20, head_sha=HEAD, head_branch=branch,
                        event=event, status='completed', conclusion='success',
                        repository=self.repo, head_repository=self.repo,
                        display_title='CI / Dependabot merge #45' if event == 'workflow_dispatch' else name)
        self.notice = dict(repository=self.repo, workflow_run=copy.deepcopy(self.run))
        self.workflow = dict(id=10, path=self.run['path'], name=name, state='active')
        self.main = dict(object=dict(type='commit', sha=HEAD))
        self.tag = dict(object=dict(type='commit', sha=HEAD))
        self.tag_object = dict(object=dict(type='commit', sha=HEAD))
        self.pr = dict(number=45, state='closed', merged=True, merge_commit_sha=HEAD,
                       user=dict(p.BOT), base=dict(ref='main', repo=self.repo), head=dict(repo=self.repo))
        self.jobs, self.checks = [], {}
        if name == 'CI':
            self.add_job('CI Plan', ['Checkout', 'Verify actual post-merge main origin', 'Plan exact changed paths', 'Preserve change selection evidence'])
            if event == 'push':
                self.jobs[0]['steps'][1]['conclusion'] = 'skipped'
            self.add_job('CI Required', ['Require every planned CI result'])
        self.add_job('Documentation / Build Documentation' if name == 'CI' else 'Build Documentation',
                     ['Checkout', 'Build Documentation', 'Upload Documentation Artifact'])
        self.artifact = dict(id=30, name=f'github-pages-{RUN}-{ATTEMPT}-{HEAD}', expired=False,
                             size_in_bytes=256, digest='sha256:' + 'c' * 64,
                             workflow_run=dict(id=RUN, repository_id=100, head_repository_id=100,
                                               head_branch=branch, head_sha=HEAD))
        self.artifacts = [self.artifact]
        self.page = dict(build_type='workflow', html_url='https://innosquadcorp.github.io/InnoFlow/')
        self.deployment = dict(id=HEAD, page_url=self.page['html_url'])
        self.statuses = ['succeed']
        self.reads, self.mutations = [], []
        self.oidc_hook = None
        self.proof_run_reads = 0
        self.fail_create = False

    def add_job(self, name, names):
        index = len(self.jobs)
        job_id, check_id = 200 + index, 300 + index
        self.jobs.append(dict(id=job_id, name=name, status='completed', conclusion='success',
                             check_run_url=f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/{check_id}',
                             steps=[dict(name=n, status='completed', conclusion='success') for n in names]))
        self.checks[str(check_id)] = dict(id=check_id, name=name, status='completed', conclusion='success',
                                        app=dict(id=p.APP), check_suite=dict(id=20), head_sha=HEAD,
                                        details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/{job_id}')

    def get(self, route):
        self.reads.append(route)
        suffix = route.removeprefix(f'repos/{p.REPOSITORY}').lstrip('/')
        if not suffix: value = self.repo
        elif suffix == f'actions/runs/{RUN}':
            self.proof_run_reads += 1
            value = self.run
        elif suffix.startswith('actions/workflows/'): value = self.workflow
        elif suffix.startswith('check-runs/'): value = self.checks[suffix.rsplit('/', 1)[1]]
        elif suffix == 'git/ref/heads/main': value = self.main
        elif suffix.startswith('git/ref/tags/'): value = self.tag
        elif suffix.startswith('git/tags/'): value = self.tag_object
        elif suffix == 'pulls/45': value = self.pr
        elif suffix == 'pages': value = self.page
        elif suffix == f'pages/deployments/{HEAD}':
            value = self.statuses[0]
            if len(self.statuses) > 1: self.statuses.pop(0)
            if isinstance(value, Exception): raise value
            if not isinstance(value, dict): value = dict(status=value)
        else: raise AssertionError('Unexpected read ' + route)
        return copy.deepcopy(value)

    def pages(self, route, key):
        self.reads.append(route)
        if route == p.route(f'actions/runs/{RUN}/attempts/{ATTEMPT}/jobs'):
            assert key == 'jobs'
            return copy.deepcopy(self.jobs)
        if route == p.route(f'actions/runs/{RUN}/artifacts'):
            assert key == 'artifacts'
            return copy.deepcopy(self.artifacts)
        raise AssertionError('Unexpected page read ' + route)

    def id_token(self):
        if self.oidc_hook: self.oidc_hook(self)
        return 'not-a-real-token'

    def mutate(self, route, data):
        self.mutations.append((route, copy.deepcopy(data)))
        if route.endswith('/cancel'): return None
        if self.fail_create: raise OSError('ambiguous create response')
        assert route == p.route('pages/deployments')
        return copy.deepcopy(self.deployment)


class PublisherProofTests(unittest.TestCase):
    def reject(self, change, **kwargs):
        api = Transcript(**kwargs)
        change(api)
        with self.assertRaises((p.Rejected, KeyError, TypeError, ValueError)):
            p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(api.mutations, [])

    def test_current_main_push_and_verified_recovery_publish_once(self):
        for event in ['push', 'workflow_dispatch']:
            api = Transcript(event=event)
            self.assertEqual(p.publish(api, api.notice), api.page['html_url'])
            self.assertEqual(len(api.mutations), 1)
            route, data = api.mutations[0]
            self.assertEqual(route, p.route('pages/deployments'))
            self.assertEqual(data['artifact_id'], api.artifact['id'])
            self.assertEqual(data['pages_build_version'], HEAD)
            self.assertEqual(api.reads.count(p.route('git/ref/heads/main')), 3)
            self.assertEqual(api.proof_run_reads, 2)
            self.assertFalse(any('/zip' in path or '/download' in path for path in api.reads))

    def test_standalone_manual_and_numeric_current_tag(self):
        for event, branch in [('workflow_dispatch', 'main'), ('push', '6.0.0'), ('workflow_dispatch', '6.0.0')]:
            api = Transcript(name='Documentation', event=event, branch=branch)
            p.publish(api, api.notice)
            self.assertEqual(len(api.mutations), 1)
        api = Transcript(name='Documentation', branch='6.0.0')
        api.tag['object'] = dict(type='tag', sha=OLD)
        p.publish(api, api.notice)
        self.assertIn(p.route('git/tags/' + OLD), api.reads)

    def test_publisher_requires_trusted_default_branch_execution(self):
        env = dict(GITHUB_REPOSITORY=p.REPOSITORY, GITHUB_EVENT_NAME='workflow_run', GITHUB_REF='refs/heads/main',
                   GITHUB_WORKFLOW_REF=f'{p.REPOSITORY}/.github/workflows/docs-publish.yml@refs/heads/main', GITHUB_WORKFLOW_SHA=HEAD)
        p.environment(env)
        for key, value in [('GITHUB_REPOSITORY', 'fork/InnoFlow'), ('GITHUB_EVENT_NAME', 'pull_request_target'),
                           ('GITHUB_REF', 'refs/pull/45/merge'), ('GITHUB_WORKFLOW_REF', f'{p.REPOSITORY}/.github/workflows/docs-publish.yml@refs/heads/develop'),
                           ('GITHUB_WORKFLOW_SHA', 'main')]:
            with self.subTest(key=key), self.assertRaises(p.Rejected): p.environment(dict(env, **{key: value}))

    def test_wrong_repository_workflow_event_sha_and_latest_attempt(self):
        changes = [lambda a: a.repo.update(default_branch='develop'),
                   lambda a: a.run.update(repository=dict(id=111, full_name=p.REPOSITORY)),
                   lambda a: a.run.update(head_repository=dict(id=111, full_name=p.REPOSITORY)),
                   lambda a: a.run.update(path='.github/workflows/else.yml'),
                   lambda a: a.workflow.update(id=11), lambda a: a.workflow.update(name='Fake CI'),
                   lambda a: a.workflow.update(state='disabled_manually'),
                   lambda a: a.run.update(head_sha=OLD), lambda a: a.run.update(run_attempt=1),
                   lambda a: a.run.update(run_attempt=3), lambda a: a.notice['workflow_run'].update(run_attempt=1),
                   lambda a: a.run.update(status='in_progress'), lambda a: a.run.update(conclusion='failure')]
        for change in changes:
            with self.subTest(change=change): self.reject(change)
        for event in ['pull_request', 'pull_request_target', 'merge_group']:
            self.reject(lambda _: None, event=event)
        self.reject(lambda _: None, branch='develop')

    def test_wrong_app_suite_head_job_and_incomplete_build_or_upload(self):
        changes = [lambda a: a.checks['302']['app'].update(id=999),
                   lambda a: a.checks['302']['check_suite'].update(id=999),
                   lambda a: a.checks['302'].update(head_sha=OLD),
                   lambda a: a.checks['302'].update(name='Build Documentation'),
                   lambda a: a.checks['302'].update(details_url=f'https://github.com/{p.REPOSITORY}/actions/runs/{RUN}/job/999'),
                   lambda a: a.jobs[-1].update(check_run_url='https://evil.test/check-runs/302'),
                   lambda a: a.jobs[-1].update(conclusion='skipped'),
                   lambda a: a.jobs.pop(), lambda a: a.jobs.append(copy.deepcopy(a.jobs[-1])),
                   lambda a: a.jobs[-1]['steps'].pop(),
                   lambda a: a.jobs[-1]['steps'][1].update(conclusion='skipped'),
                   lambda a: a.jobs[-1]['steps'][2].update(conclusion='skipped'),
                   lambda a: a.jobs[-1]['steps'][2].update(status='in_progress'),
                   lambda a: a.jobs[-1]['steps'][2].update(conclusion='failure'),
                   lambda a: a.jobs[1]['steps'].clear(),
                   lambda a: a.jobs[0]['steps'][2].update(conclusion='skipped')]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_forged_recovery_marker_origin_and_skipped_validation(self):
        changes = [lambda a: a.run.update(display_title='CI'),
                   lambda a: a.run.update(display_title='CI / Dependabot merge #45 extra'),
                   lambda a: a.pr.update(user=dict(login='dependabot[bot]', id=123, type='Bot')),
                   lambda a: a.pr.update(merged=False), lambda a: a.pr.update(state='open'),
                   lambda a: a.pr.update(merge_commit_sha=OLD),
                   lambda a: a.pr['base'].update(ref='develop'),
                   lambda a: a.pr['head'].update(repo=dict(id=101, full_name=p.REPOSITORY)),
                   lambda a: a.jobs[0]['steps'][1].update(conclusion='skipped')]
        for change in changes:
            with self.subTest(change=change): self.reject(change, event='workflow_dispatch')

    def test_artifact_origin_attempt_digest_and_completeness(self):
        changes = [lambda a: a.artifacts.clear(), lambda a: a.artifacts.append(copy.deepcopy(a.artifact)),
                   lambda a: a.artifact.update(name=f'github-pages-{RUN}-1-{HEAD}'),
                   lambda a: a.artifact.update(expired=True), lambda a: a.artifact.update(size_in_bytes=0),
                   lambda a: a.artifact.update(digest=None), lambda a: a.artifact.update(digest=''),
                   lambda a: a.artifact.update(id=0), lambda a: a.artifact.update(workflow_run={}),
                   lambda a: a.artifact['workflow_run'].update(id=RUN - 1),
                   lambda a: a.artifact['workflow_run'].update(repository_id=101),
                   lambda a: a.artifact['workflow_run'].update(head_repository_id=101),
                   lambda a: a.artifact['workflow_run'].update(head_sha=OLD),
                   lambda a: a.artifact['workflow_run'].update(head_branch='feature')]
        for change in changes:
            with self.subTest(change=change): self.reject(change)

    def test_stale_main_moved_tag_and_branch_push_are_rejected(self):
        self.reject(lambda a: a.main['object'].update(sha=OLD))
        self.reject(lambda a: a.tag['object'].update(sha=OLD), name='Documentation', branch='6.0.0')
        self.reject(lambda a: a.main['object'].update(sha=OLD), name='Documentation', branch='6.0.0')
        self.reject(lambda _: None, name='Documentation', branch='main')
        self.reject(lambda _: None, name='Documentation', branch='v6.0.0')
        self.reject(lambda _: None, name='Documentation', event='workflow_dispatch', branch='feature')

    def test_ref_attempt_or_upload_race_before_mutation(self):
        for hook in [lambda a: a.main['object'].update(sha=OLD),
                     lambda a: a.run.update(run_attempt=3),
                     lambda a: a.artifact.update(id=31),
                     lambda a: a.jobs[-1]['steps'][2].update(conclusion='failure')]:
            self.reject(lambda a: setattr(a, 'oidc_hook', hook))
        self.reject(lambda a: a.page.update(build_type='legacy'))

    def test_pages_poll_failure_and_timeout_never_create_twice(self):
        api = Transcript()
        api.statuses = ['deployment_attempt_error', 'deployment_in_progress', 'succeed']
        p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(len(api.mutations), 1)
        api = Transcript()
        api.statuses = ['deployment_failed']
        with self.assertRaises(p.Rejected): p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(len(api.mutations), 1)
        api = Transcript()
        api.statuses = ['deployment_in_progress']
        with self.assertRaises(p.Rejected): p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual([path.rsplit('/', 1)[1] for path, _ in api.mutations], ['deployments', 'cancel'])
        api = Transcript()
        api.fail_create = True
        with self.assertRaises(OSError): p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual(len(api.mutations), 1)

    def test_each_official_intermediate_status_waits_for_explicit_success(self):
        # Independent API-schema expectations, not imported from the publisher.
        # https://docs.github.com/en/rest/pages/pages#get-the-status-of-a-github-pages-deployment
        for state in ['deployment_in_progress', 'syncing_files', 'finished_file_sync',
                      'updating_pages', 'purging_cdn']:
            with self.subTest(state=state):
                api = Transcript()
                api.statuses = [state, state, 'succeed', 'deployment_failed']
                sleep = mock.Mock()
                self.assertEqual(p.publish(api, api.notice, sleep=sleep), api.page['html_url'])
                self.assertEqual(sleep.call_args_list, [mock.call(5), mock.call(5)])
                self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 3)
                self.assertEqual(len(api.mutations), 1)

    def test_official_lifecycle_and_existing_temporary_statuses_recover(self):
        api = Transcript()
        api.statuses = ['queued', 'pending', 'unknown_status', 'not_found',
                        'deployment_attempt_error', 'deployment_in_progress', 'syncing_files',
                        'finished_file_sync', 'updating_pages', 'purging_cdn', 'succeed']
        sleep = mock.Mock()
        self.assertEqual(p.publish(api, api.notice, sleep=sleep), api.page['html_url'])
        self.assertEqual(sleep.call_args_list, [mock.call(5)] * 10)
        self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 11)
        self.assertEqual(len(api.mutations), 1)

    def test_every_terminal_failure_stops_without_retry_or_cancellation(self):
        for state in ['deployment_failed', 'deployment_content_failed',
                      'deployment_cancelled', 'deployment_lost']:
            with self.subTest(state=state):
                api = Transcript()
                api.statuses = ['syncing_files', state, 'succeed']
                sleep = mock.Mock()
                with self.assertRaises(p.Rejected) as caught:
                    p.publish(api, api.notice, sleep=sleep)
                self.assertEqual(str(caught.exception), 'Pages deployment failed: ' + state)
                sleep.assert_called_once_with(5)
                self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 2)
                self.assertEqual(len(api.mutations), 1)

    def test_unknown_status_reports_exact_value_and_cancels_once(self):
        # deployment_queued is not in the official schema; do not guess that a
        # similar-looking or undocumented value is success or safe to poll.
        for state in ['deployment_queued', 'success', 'SUCCEED', 'succeed ',
                      'new_status', '', None, False, 1, ['succeed'], {'state': 'succeed'},
                      'new\n::warning::status\r\t']:
            with self.subTest(state=state):
                api = Transcript()
                api.statuses = [{'status': state}, 'succeed']
                sleep = mock.Mock()
                with self.assertRaises(p.Rejected) as caught:
                    p.publish(api, api.notice, sleep=sleep)
                self.assertEqual(str(caught.exception),
                                 f'Unknown Pages status {state!r}; cancellation requested')
                self.assertNotIn('\n', str(caught.exception))
                sleep.assert_not_called()
                self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 1)
                self.assertEqual([path for path, _ in api.mutations],
                                 [p.route('pages/deployments'), p.route('pages/deployments/' + HEAD + '/cancel')])
                self.assertEqual(api.mutations[-1][1], {})

    def test_missing_status_is_rejected_and_cancelled(self):
        api = Transcript()
        api.statuses = [{}, 'succeed']
        with self.assertRaisesRegex(p.Rejected, 'Unknown Pages status None; cancellation requested'):
            p.publish(api, api.notice, sleep=lambda _: None)
        self.assertEqual([path for path, _ in api.mutations],
                         [p.route('pages/deployments'), p.route('pages/deployments/' + HEAD + '/cancel')])
        self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 1)

    def test_every_new_intermediate_state_remains_bounded_by_poll_limit(self):
        for state in ['syncing_files', 'finished_file_sync', 'updating_pages', 'purging_cdn']:
            with self.subTest(state=state), mock.patch.object(p.time, 'monotonic', return_value=0):
                api = Transcript()
                api.statuses = [state] * 120 + ['succeed']
                sleep = mock.Mock()
                with self.assertRaisesRegex(p.Rejected, 'timed out and cancellation was requested'):
                    p.publish(api, api.notice, sleep=sleep)
                self.assertEqual(sleep.call_args_list, [mock.call(5)] * 120)
                self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 120)
                self.assertEqual([path for path, _ in api.mutations],
                                 [p.route('pages/deployments'), p.route('pages/deployments/' + HEAD + '/cancel')])

    def test_elapsed_deadline_cancels_before_reading_a_late_success(self):
        api = Transcript()
        api.statuses = ['syncing_files', 'succeed']
        sleep = mock.Mock()
        with mock.patch.object(p.time, 'monotonic', side_effect=[100, 100, 700]):
            with self.assertRaisesRegex(p.Rejected, 'timed out and cancellation was requested'):
                p.publish(api, api.notice, sleep=sleep)
        sleep.assert_called_once_with(5)
        self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 1)
        self.assertEqual([path for path, _ in api.mutations],
                         [p.route('pages/deployments'), p.route('pages/deployments/' + HEAD + '/cancel')])
        api = Transcript()
        with mock.patch.object(p.time, 'monotonic', side_effect=[100, 699.999]):
            self.assertEqual(p.publish(api, api.notice), api.page['html_url'])
        self.assertEqual(len(api.mutations), 1)

    def test_status_request_error_budget_is_cumulative_and_never_recreates(self):
        for errors in [9, 10]:
            with self.subTest(errors=errors), mock.patch.object(p.time, 'monotonic', return_value=0):
                api = Transcript()
                api.statuses = []
                for _ in range(errors):
                    api.statuses.extend([p.urllib.error.URLError('status unavailable'), 'syncing_files'])
                api.statuses.append('succeed')
                sleep = mock.Mock()
                if errors == 9:
                    self.assertEqual(p.publish(api, api.notice, sleep=sleep), api.page['html_url'])
                    self.assertEqual(len(api.mutations), 1)
                else:
                    with self.assertRaisesRegex(p.Rejected, 'Pages status unavailable; cancellation requested'):
                        p.publish(api, api.notice, sleep=sleep)
                    self.assertEqual([path for path, _ in api.mutations],
                                     [p.route('pages/deployments'), p.route('pages/deployments/' + HEAD + '/cancel')])
                self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 19)
                self.assertEqual(sleep.call_args_list, [mock.call(5)] * 18)

    def test_cancel_failure_does_not_retry_cancel_create_or_report_success(self):
        for states in [['new_status'], ['syncing_files'], [p.urllib.error.URLError('status unavailable')]]:
            with self.subTest(states=states), mock.patch.object(p.time, 'monotonic', return_value=0):
                api = Transcript()
                api.statuses = states
                mutate = api.mutate
                def failed_cancel(route, data):
                    result = mutate(route, data)
                    if route.endswith('/cancel'):
                        raise p.urllib.error.URLError('cancel unavailable')
                    return result
                api.mutate = failed_cancel
                with self.assertRaisesRegex(p.urllib.error.URLError, 'cancel unavailable'):
                    p.publish(api, api.notice, sleep=lambda _: None)
                self.assertEqual([path for path, _ in api.mutations],
                                 [p.route('pages/deployments'), p.route('pages/deployments/' + HEAD + '/cancel')])

    def test_unknown_status_is_logged_before_an_unsuccessful_cancel(self):
        api = Transcript()
        api.statuses = ['new\n::warning::status\r\t', 'succeed']
        stderr = io.StringIO()
        expected = "Unknown Pages status 'new\\n::warning::status\\r\\t'; requesting cancellation\n"
        failure = p.urllib.error.URLError('cancel unavailable')
        mutate = api.mutate
        def failed_cancel(route, data):
            result = mutate(route, data)
            if route.endswith('/cancel'):
                self.assertEqual(stderr.getvalue(), expected)
                raise failure
            return result
        api.mutate = failed_cancel
        sleep = mock.Mock()
        with mock.patch.object(p.sys, 'stderr', stderr), self.assertRaises(p.urllib.error.URLError) as caught:
            p.publish(api, api.notice, sleep=sleep)
        self.assertIs(caught.exception, failure)
        self.assertEqual(stderr.getvalue(), expected)
        sleep.assert_not_called()
        self.assertEqual(api.reads.count(p.route('pages/deployments/' + HEAD)), 1)
        self.assertEqual([path for path, _ in api.mutations],
                         [p.route('pages/deployments'), p.route('pages/deployments/' + HEAD + '/cancel')])

    def test_last_main_read_and_status_read_errors_are_fail_closed(self):
        api = Transcript()
        api.statuses = ['syncing_files', 'succeed']
        original = api.get
        main_reads = 0
        def moved_on_final_read(route):
            nonlocal main_reads
            if route == p.route('git/ref/heads/main'):
                main_reads += 1
                if main_reads == 3: api.main['object']['sha'] = OLD
            return original(route)
        api.get = moved_on_final_read
        with self.assertRaisesRegex(p.Rejected, 'source is not current main'):
            p.publish(api, api.notice)
        self.assertEqual(api.mutations, [])
        self.assertNotIn(p.route('pages/deployments/' + HEAD), api.reads)
        for temporary in [True, False]:
            api = Transcript()
            original = api.get
            failures = 0
            def unavailable_status(route):
                nonlocal failures
                if '/pages/deployments/' in route and (not temporary or failures == 0):
                    failures += 1
                    raise p.urllib.error.URLError('temporary status outage')
                return original(route)
            api.get = unavailable_status
            if temporary:
                p.publish(api, api.notice, sleep=lambda _: None)
                self.assertEqual(len(api.mutations), 1)
            else:
                with self.assertRaises(p.Rejected): p.publish(api, api.notice, sleep=lambda _: None)
                self.assertEqual([path.rsplit('/', 1)[1] for path, _ in api.mutations], ['deployments', 'cancel'])

    def test_every_api_page_is_consumed_without_following_external_links(self):
        api = object.__new__(p.GitHub)
        calls = []
        def request(method, path):
            calls.append(path)
            if path.endswith('&page=1'): return {'jobs': [1]}, {'Link': '<https://evil.test/>; rel="next"'}
            return {'jobs': [2]}, {}
        api.request = request
        self.assertEqual(api.pages(p.route('actions/runs/91/attempts/2/jobs'), 'jobs'), [1, 2])
        self.assertTrue(all(path.startswith(p.route()) for path in calls))
        api.request = lambda method, path: ({'jobs': [1], 'total_count': 2}, {})
        with self.assertRaisesRegex(p.Rejected, 'truncated'):
            api.pages(p.route('actions/runs/91/attempts/2/jobs'), 'jobs')


    def test_workflow_split_is_read_only_build_and_trusted_api_publisher(self):
        build = (ROOT / '.github/workflows/docs.yml').read_text()
        publish = (ROOT / '.github/workflows/docs-publish.yml').read_text()
        self.assertIn('  workflow_call:', build)
        self.assertNotIn('  pull_request:', build)
        self.assertNotIn('    branches:', build)
        self.assertNotIn('write', '\n'.join(re.findall(r'^\s+(?:contents|actions|pages|id-token):.*$', build, re.M)))
        self.assertNotIn('deploy-pages@', build)
        self.assertNotIn('configure-pages@', build)
        self.assertNotIn('deploy-docs:', build)
        self.assertIn('github-pages-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.sha }}', build)
        self.assertIn('Tools/generate-docc.sh docs-build InnoFlow InnoFlow', build)
        self.assertIn('    workflows: [CI, Documentation]', publish)
        self.assertIn("github.workflow_ref == 'InnoSquadCorp/InnoFlow/.github/workflows/docs-publish.yml@refs/heads/main'", publish)
        self.assertIn('ref: ${{ github.workflow_sha }}', publish)
        self.assertIn('sparse-checkout: scripts/publish-docs.py', publish)
        self.assertIn('persist-credentials: false', publish)
        self.assertIn('run: python3 -B scripts/publish-docs.py', publish)
        self.assertNotIn('\nconcurrency:', publish)  # Ineligible PR notifications cannot evict a queued deployment.
        for forbidden in ['workflow_run.head_sha }}', 'download-artifact', 'cache@', 'secrets.', 'continue-on-error']:
            self.assertNotIn(forbidden, publish)


if __name__ == '__main__':
    unittest.main()
