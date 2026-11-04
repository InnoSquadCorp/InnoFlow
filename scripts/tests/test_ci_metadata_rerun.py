"""A metadata recheck that outwaited its queued validation is rerun once, exactly."""
import copy
import importlib.util
import os
from pathlib import Path
import re
import unittest
from unittest import mock

import test_ci_metadata_policy as meta
import test_dependabot_merge_policy as bot

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('metadata_rerun', ROOT / 'scripts/ci-metadata-rerun.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
p = bot.p
META = meta.META
VALIDATED = '2026-11-04T07:00:00Z'
TARGET = dict(pr=bot.NUMBER, head=bot.HEAD, run=META, attempt=1)
BACKGROUND = dict(bot.TRUSTED, GITHUB_EVENT_NAME='workflow_run', GITHUB_JOB=r.JOB, PR_NUMBERS=f'[{bot.NUMBER}]')


class RerunAPI(meta.MetadataAPI):
    """Validation finished after a metadata attempt failed its bounded wait."""

    def __init__(self):
        super().__init__(bot.Transcript(), bot.NUMBER, bot.HEAD, bot.BASE, bot.MERGE)
        self.base.run.update(display_title=f'CI validation v2 pr:{bot.NUMBER} head:{bot.HEAD} base:{bot.BASE} '
                                           f'source:{bot.MERGE} release:true asan:false concurrency:false')
        required = next(j for j in self.base.jobs if j['name'] == 'CI Required')
        required['completed_at'] = VALIDATED
        self.run.update(conclusion='failure', run_started_at='2026-11-04T01:50:35Z',
                        display_title=self.run['display_title'].replace('source:' + meta.SOURCE, 'source:' + bot.MERGE))
        meta.fail_gates(self.jobs, self.checks)
        self.posts, self.accept = [], True

    def mutate(self, method, route, payload):
        self.posts.append((method, route, copy.deepcopy(payload)))
        if not self.accept:
            raise OSError('lost reply')
        self.rerun()
        self.run.update(status='queued', conclusion=None)
        return None


class MetadataRerunTests(unittest.TestCase):
    def test_plans_only_the_failed_wait_that_began_before_validation_finished(self):
        self.assertEqual(r.targets(RerunAPI(), p, bot.NUMBER), [TARGET])

    def test_nothing_is_planned_when_a_rerun_could_not_pass_or_is_not_needed(self):
        cases = {
            'attempt began after validation': lambda a: a.run.update(run_started_at='2026-11-04T07:00:01Z'),
            'validation running': lambda a: a.base.run.update(status='in_progress', conclusion=None),
            'validation failed': lambda a: a.base.run.update(conclusion='failure'),
            'validation of an older merge': lambda a: a.base.run.update(
                display_title=a.base.run['display_title'].replace(bot.MERGE, 'e' * 40)),
            'validation of another PR': lambda a: a.base.run.update(
                display_title=a.base.run['display_title'].replace(f'pr:{bot.NUMBER}', 'pr:46')),
            'validation title forged': lambda a: a.base.run.update(display_title='CI validation v2 forged'),
            'metadata of an older merge': lambda a: a.run.update(
                display_title=a.run['display_title'].replace(bot.MERGE, 'e' * 40)),
            'metadata of another head': lambda a: a.run.update(
                display_title=a.run['display_title'].replace(f'head:{bot.HEAD}', 'head:' + '0' * 40)),
            'metadata succeeded': lambda a: a.run.update(conclusion='success'),
            'metadata running': lambda a: a.run.update(status='in_progress', conclusion=None),
            'metadata cancelled': lambda a: a.run.update(conclusion='cancelled'),
            'metadata historical': lambda a: a.run.update(run_number=29),
            'foreign workflow': lambda a: a.run.update(workflow_id=999),
            'foreign head repository': lambda a: a.run.update(head_repository=dict(id=999)),
            'attempt cap': lambda a: a.run.update(run_attempt=r.MAX_ATTEMPTS),
            'validation work executed': lambda a: next(j for j in a.jobs if j['name'] not in meta.m.GATES).update(
                conclusion='failure'),
            'main moved': lambda a: setattr(a.base, 'base', 'e' * 40),
            'no test merge': lambda a: a.base.pr.update(merge_commit_sha=None),
            'closed PR': lambda a: a.base.pr.update(state='closed'),
            'fork PR': lambda a: a.base.pr['head'].update(repo=dict(id=999)),
        }
        for name, change in cases.items():
            api = RerunAPI()
            change(api)
            with self.subTest(name):
                self.assertEqual(r.targets(api, p, bot.NUMBER), [])
                self.assertEqual(api.posts, [])

    def test_untrusted_evidence_rejects_instead_of_guessing(self):
        for change in (lambda a: a.base.workflow.update(state='disabled_manually'),
                       lambda a: next(j for j in a.base.jobs if j['name'] == 'CI Required').update(completed_at=None),
                       lambda a: next(j for j in a.base.jobs if j['name'] == 'CI Required').update(conclusion='failure'),
                       lambda a: a.run.update(run_started_at='2026-11-04T01:50:35')):
            api = RerunAPI()
            change(api)
            with self.assertRaises(p.Rejected):
                r.targets(api, p, bot.NUMBER)

    def test_one_exact_rerun_is_requested_and_not_repeated(self):
        api = RerunAPI()
        self.assertIn('rerun requested', r.request(api, p, TARGET))
        self.assertEqual(api.posts, [('POST', f'repos/{p.REPOSITORY}/actions/runs/{META}/rerun', {})])
        self.assertIn('no longer eligible', r.request(api, p, TARGET))
        self.assertEqual(len(api.posts), 1)
        self.assertEqual(r.targets(api, p, bot.NUMBER), [])

    def test_a_rerun_that_fails_after_validation_finished_is_never_retried(self):
        api = RerunAPI()
        r.request(api, p, TARGET)
        meta.fail_gates(api.jobs, api.checks)
        api.run.update(status='completed', conclusion='failure', run_started_at='2026-11-04T07:05:00Z')
        self.assertEqual(r.targets(api, p, bot.NUMBER), [])

    def test_an_unconfirmed_request_is_reported_without_a_second_post(self):
        api = RerunAPI()
        api.accept = False
        with mock.patch.object(r.time, 'sleep'), self.assertRaisesRegex(p.Rejected, 'unconfirmed'):
            r.request(api, p, TARGET)
        self.assertEqual(len(api.posts), 1)

    def test_entrypoint_requires_the_trusted_background_writer(self):
        api = RerunAPI()
        with mock.patch.object(r, 'load', return_value=p), mock.patch.object(p, 'GitHub', return_value=api), \
                mock.patch.dict(os.environ, BACKGROUND, clear=True):
            self.assertEqual(r.main(), 0)
        self.assertEqual(len(api.posts), 1)
        for change in (dict(GITHUB_EVENT_NAME='pull_request_target'), dict(GITHUB_JOB='ready-refresh'),
                       dict(GITHUB_REF='refs/heads/unmerged'), dict(PR_NUMBERS='[45, 45]'), dict(PR_NUMBERS='["45"]')):
            api = RerunAPI()
            with mock.patch.object(r, 'load', return_value=p), mock.patch.object(p, 'GitHub', return_value=api), \
                    mock.patch.dict(os.environ, dict(BACKGROUND, **change), clear=True), self.subTest(change=change):
                self.assertEqual(r.main(), 1)
                self.assertEqual(api.posts, [])

    def test_coordinator_runs_the_writer_only_for_trusted_background_events(self):
        source = (ROOT / '.github/workflows/dependabot-auto-merge.yml').read_text()
        job = source.split('\n  metadata-rerun:\n', 1)[1]
        expression = re.search(r'(?m)^    if: (.*)', job)[1]
        def allowed(**overrides):
            values = {'needs.inspect.result': 'success', 'github.repository': p.REPOSITORY,
                      'github.ref': 'refs/heads/main', 'github.event_name': 'workflow_run',
                      'github.workflow_ref': p.REPOSITORY + '/.github/workflows/dependabot-auto-merge.yml@refs/heads/main',
                      'needs.inspect.outputs.prs': '[73]'}
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
        self.assertIn('    permissions:\n      contents: read\n      actions: write\n      pull-requests: read\n', job)
        self.assertIn('run: python3 -B scripts/ci-metadata-rerun.py', job)
        self.assertIn('group: ci-metadata-rerun', job)


if __name__ == '__main__':
    unittest.main()
