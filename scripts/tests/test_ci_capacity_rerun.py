"""Validation jobs GitHub never gave a hosted runner are rerun once, exactly."""
import copy
import importlib.util
import io
import os
from pathlib import Path
import re
import unittest
from unittest import mock

import test_dependabot_merge_policy as bot

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('capacity_rerun', ROOT / 'scripts/ci-capacity-rerun.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
p = bot.p
SMOKE = 'Canonical Sample UI Smoke Tests'
TARGET = dict(pr=bot.NUMBER, head=bot.HEAD, run=bot.RUN, attempt=1)
BACKGROUND = dict(bot.TRUSTED, GITHUB_EVENT_NAME='workflow_run', GITHUB_JOB=r.JOB, PR_NUMBERS=f'[{bot.NUMBER}]')
NOTICE = 'Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.'


def check_id(job):
    return int(job['check_run_url'].rsplit('/', 1)[1])


class CapacityAPI(bot.Transcript):
    """PR #77 run 42005581343: the UI smoke job never got a runner and CI Required failed."""

    def __init__(self):
        super().__init__()
        self.run.update(conclusion='failure', display_title=(
            f'CI validation v2 pr:{bot.NUMBER} head:{bot.HEAD} base:{bot.BASE} source:{bot.MERGE} '
            'release:true asan:false concurrency:false'))
        self.annotations = {}
        self.cancel(SMOKE)
        required = next(j for j in self.jobs if j['name'] == 'CI Required')
        required.update(conclusion='failure')
        required['steps'] = [dict(name='Set up job', status='completed', conclusion='success'),
                             dict(name=r.METADATA.GATES['CI Required'], status='completed', conclusion='failure'),
                             dict(name='Verify prior validation for metadata', status='completed', conclusion='skipped')]
        self.posts, self.accept = [], True

    def cancel(self, name, message=r.CAPACITY):
        job = next(j for j in self.jobs if j['name'] == name)
        job.update(conclusion='cancelled', runner_id=0, runner_name='', steps=[])
        self.annotations[check_id(job)] = [dict(annotation_level='failure', message=message),
                                           dict(annotation_level='notice', message=NOTICE)]
        return job

    def get(self, route):
        found = re.fullmatch(rf'repos/{p.REPOSITORY}/actions/runs/([0-9]+)', route)
        if found and int(found[1]) != bot.RUN:
            self.reads.append(route)
            return copy.deepcopy(next(run for run in self.runs if run['id'] == int(found[1])))
        return super().get(route)

    def pages(self, route, key=None):
        found = re.fullmatch(rf'repos/{p.REPOSITORY}/check-runs/([0-9]+)/annotations', route)
        if found:
            self.reads.append(route)
            return copy.deepcopy(self.annotations.get(int(found[1]), []))
        if route == f'repos/{p.REPOSITORY}/actions/runs/{bot.RUN}/attempts/1/jobs':
            # The interrupted first attempt stays readable after a rerun.
            self.reads.append(route)
            return copy.deepcopy(self.jobs)
        return super().pages(route, key)

    def mutate(self, method, route, payload):
        self.posts.append((method, route, copy.deepcopy(payload)))
        if not self.accept:
            raise OSError('lost reply')
        self.run.update(run_attempt=self.run['run_attempt'] + 1, status='queued', conclusion=None)
        return None


class CapacityRerunTests(unittest.TestCase):
    def test_plans_the_latest_validation_that_only_runner_capacity_cancelled(self):
        self.assertEqual(r.targets(CapacityAPI(), p, bot.NUMBER), [TARGET])
        api = CapacityAPI()
        for name in ('Lint', 'Package Build (macOS)'):
            api.cancel(name)
        next(j for j in api.jobs if j['name'] == 'Coverage Gate / coverage').update(conclusion='skipped', steps=[])
        self.assertEqual(r.targets(api, p, bot.NUMBER), [TARGET])
        api = CapacityAPI()
        api.runs.append(dict(api.run, id=bot.RUN + 1, run_number=31, conclusion='failure', display_title=(
            f'CI metadata-only v1 pr:{bot.NUMBER} head:{bot.HEAD} base:{bot.BASE} action:edited source:{bot.MERGE}')))
        self.assertEqual(r.targets(api, p, bot.NUMBER), [TARGET])

    def test_nothing_is_planned_when_the_failure_is_the_change_or_already_handled(self):
        def job(name):
            return lambda a: next(j for j in a.jobs if j['name'] == name)
        cases = {
            'real job failure': lambda a: job('Lint')(a).update(conclusion='failure'),
            'cancelled after a runner took it': lambda a: job(SMOKE)(a).update(runner_id=1000052823, runner_name='GitHub Actions 1000052823'),
            'cancelled after steps ran': lambda a: job(SMOKE)(a).update(steps=[dict(name='Set up job', conclusion='success')]),
            'cancelled by a newer push': lambda a: a.cancel(SMOKE, 'Canceling since a higher priority waiting request for ci-CI-77-validation exists'),
            'capacity notice only': lambda a: a.annotations.update({check_id(job(SMOKE)(a)): [dict(annotation_level='notice', message=NOTICE)]}),
            'capacity text as a warning': lambda a: a.annotations.update({check_id(job(SMOKE)(a)): [dict(annotation_level='warning', message=r.CAPACITY)]}),
            'timed out': lambda a: job(SMOKE)(a).update(conclusion='timed_out'),
            'aggregate failed outside aggregation': lambda a: job('CI Required')(a)['steps'][0].update(conclusion='failure'),
            'only the aggregate failed': lambda a: job(SMOKE)(a).update(conclusion='success', runner_id=7, steps=[dict(name='Run', conclusion='success')]),
            'rerun already used': lambda a: a.run.update(run_attempt=2),
            'validation running': lambda a: a.run.update(status='in_progress', conclusion=None),
            'validation succeeded': lambda a: a.run.update(conclusion='success'),
            'newer validation': lambda a: a.runs.append(dict(a.run, id=bot.RUN + 1, run_number=31, status='queued', conclusion=None)),
            'validation of another PR': lambda a: a.run.update(display_title=a.run['display_title'].replace(f'pr:{bot.NUMBER} ', 'pr:46 ')),
            'validation of another head': lambda a: a.run.update(display_title=a.run['display_title'].replace(f'head:{bot.HEAD}', 'head:' + '0' * 40)),
            'validation title forged': lambda a: a.run.update(display_title='CI validation v2 forged'),
            'foreign workflow': lambda a: a.run.update(workflow_id=999),
            'foreign head repository': lambda a: a.run.update(head_repository=dict(id=999)),
            'no validation': lambda a: setattr(a, 'runs', []),
            'closed PR': lambda a: a.pr.update(state='closed'),
            'fork PR': lambda a: a.pr['head'].update(repo=dict(id=999)),
            'retargeted PR': lambda a: a.pr['base'].update(ref='release'),
        }
        for name, change in cases.items():
            api = CapacityAPI()
            change(api)
            with self.subTest(name):
                self.assertEqual(r.targets(api, p, bot.NUMBER), [])
                self.assertEqual(r.request(api, p, TARGET), f'PR{bot.NUMBER} run{bot.RUN} attempt1: no longer eligible')
                self.assertEqual(api.posts, [])

    def test_untrusted_evidence_rejects_instead_of_guessing(self):
        for change in (lambda a: a.workflow.update(state='disabled_manually'),
                       lambda a: next(j for j in a.jobs if j['name'] == SMOKE).update(check_run_url='https://example.com/1'),
                       lambda a: a.runs.append(dict(a.run, id='901'))):
            api = CapacityAPI()
            change(api)
            with self.assertRaises(p.Rejected):
                r.targets(api, p, bot.NUMBER)
            self.assertEqual(api.posts, [])

    def test_one_failed_job_rerun_is_requested_and_not_repeated(self):
        api = CapacityAPI()
        self.assertIn('capacity-cancelled jobs rerun', r.request(api, p, TARGET))
        self.assertEqual(api.posts, [('POST', f'repos/{p.REPOSITORY}/actions/runs/{bot.RUN}/rerun-failed-jobs', {})])
        self.assertIn('no longer eligible', r.request(api, p, TARGET))
        # A rerun that loses capacity again waits for an operator.
        api.run.update(status='completed', conclusion='failure')
        self.assertEqual(r.targets(api, p, bot.NUMBER), [])
        self.assertEqual(len(api.posts), 1)

    def test_an_unconfirmed_request_is_reported_without_a_second_post(self):
        api = CapacityAPI()
        api.accept = False
        with mock.patch.object(r.time, 'sleep'), mock.patch('sys.stderr', new_callable=io.StringIO) as stderr, \
                self.assertRaisesRegex(p.Rejected, 'unconfirmed'):
            r.request(api, p, TARGET)
        self.assertEqual(len(api.posts), 1)
        self.assertIn('rerun request raised OSError: lost reply', stderr.getvalue())

    def test_entrypoint_requires_the_trusted_background_writer(self):
        api = CapacityAPI()
        with mock.patch.object(r, 'load', return_value=p), mock.patch.object(p, 'GitHub', return_value=api), \
                mock.patch.dict(os.environ, BACKGROUND, clear=True):
            self.assertEqual(r.main(), 0)
        self.assertEqual(len(api.posts), 1)
        # A broken reply for one PR (normalized to ConnectionError) leaves the others to proceed.
        api = CapacityAPI()
        read = api.get
        def get(route):
            if route == f'repos/{p.REPOSITORY}/pulls/999':
                raise ConnectionError('GitHub API reply broken: IncompleteRead')
            return read(route)
        api.get = get
        with mock.patch.object(r, 'load', return_value=p), mock.patch.object(p, 'GitHub', return_value=api), \
                mock.patch.dict(os.environ, dict(BACKGROUND, PR_NUMBERS=f'[999, {bot.NUMBER}]'), clear=True), \
                mock.patch('sys.stderr', new_callable=io.StringIO) as stderr:
            self.assertEqual(r.main(), 1)
        self.assertIn('PR999: no capacity rerun: GitHub API reply broken', stderr.getvalue())
        self.assertEqual(len(api.posts), 1)
        for change in (dict(GITHUB_EVENT_NAME='pull_request_target'), dict(GITHUB_JOB='metadata-rerun'),
                       dict(GITHUB_REF='refs/heads/unmerged'), dict(PR_NUMBERS='[45, 45]'), dict(PR_NUMBERS='["45"]')):
            api = CapacityAPI()
            with mock.patch.object(r, 'load', return_value=p), mock.patch.object(p, 'GitHub', return_value=api), \
                    mock.patch.dict(os.environ, dict(BACKGROUND, **change), clear=True), self.subTest(change=change):
                self.assertEqual(r.main(), 1)
                self.assertEqual(api.posts, [])

    def test_coordinator_runs_the_writer_only_for_trusted_background_events(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        job = source.split('\n  capacity-rerun:\n', 1)[1]
        expression = re.search(r'(?m)^    if: (.*)', job)[1]
        def allowed(**overrides):
            values = {'needs.inspect.result': 'success', 'github.repository': p.REPOSITORY,
                      'github.ref': 'refs/heads/main', 'github.event_name': 'workflow_run',
                      'github.workflow_ref': p.REPOSITORY + '/.github/workflows/dependabot-auto-merge.yml@refs/heads/main',
                      'needs.inspect.outputs.prs': '[77]'}
            values.update(overrides)
            evaluated = expression
            for name, value in values.items():
                evaluated = evaluated.replace(name, repr(value))
            return eval(evaluated.replace('&&', 'and').replace('||', 'or'), {'__builtins__': {}})
        for event in ('workflow_run', 'schedule', 'push', 'workflow_dispatch'):
            self.assertTrue(allowed(**{'github.event_name': event}))
        for change in ({'github.event_name': 'pull_request_target'}, {'github.ref': 'refs/heads/unmerged'},
                       {'github.workflow_ref': 'branch workflow'}, {'needs.inspect.result': 'failure'},
                       {'needs.inspect.outputs.prs': '[]'}, {'needs.inspect.outputs.prs': ''}):
            self.assertFalse(allowed(**change))
        self.assertIn('    permissions:\n      contents: read\n      actions: write\n      checks: read\n'
                      '      pull-requests: read\n', job)
        self.assertIn('run: python3 -B scripts/ci-capacity-rerun.py', job)
        self.assertIn('group: ci-capacity-rerun', job)


if __name__ == '__main__':
    unittest.main()
