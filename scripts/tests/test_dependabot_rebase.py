"""One stale Dependabot update at a time gets exactly one rebase request."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import os
from pathlib import Path
import re
import unittest
from unittest import mock

import test_dependabot_merge_policy as bot

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('dependabot_rebase', ROOT / 'scripts/dependabot-rebase.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
p = bot.p
MAIN, OLD = 'f' * 40, 'e' * 40
NOW = datetime(2026, 11, 6, 3, 0, tzinfo=timezone.utc)
COMMITTED = '2026-11-06T01:00:00Z'
TRUSTED = dict(GITHUB_REPOSITORY=p.REPOSITORY, GITHUB_REF='refs/heads/main', GITHUB_WORKFLOW_REF=r.WORKFLOW_REF,
               GITHUB_EVENT_NAME='push', GH_TOKEN='job-token')


def stamp(moment):
    return moment.strftime('%Y-%m-%dT%H:%M:%SZ')


class RebaseAPI:
    """Open Dependabot updates #71 and #73 were left on an obsolete base by a main change."""

    def __init__(self):
        self.repo = dict(id=100, full_name=p.REPOSITORY)
        self.workflow = dict(id=10, path=p.CI_PATH, state='active')
        self.prs, self.runs, self.comments, self.commits = {}, {}, {}, {}
        for number in (73, 71):
            self.add(number)
        self.posts = []

    def add(self, number, base=OLD, user=None):
        head = format(number, 'x') * 40
        head = head[:40]
        self.prs[number] = dict(number=number, state='open', draft=False, user=dict(user or p.BOT),
                                base=dict(ref='main', sha=base, repo=self.repo), head=dict(sha=head, repo=self.repo))
        self.commits[head] = dict(sha=head, committer=dict(date=COMMITTED))
        self.runs[head], self.comments[number] = [], []
        return self.prs[number]

    def validate(self, number, status='completed', conclusion='success', run_number=50):
        head = self.prs[number]['head']['sha']
        self.runs[head].append(dict(id=run_number, run_number=run_number, workflow_id=10, status=status,
                                    conclusion=conclusion, display_title=(
                                        f'CI validation v2 pr:{number} head:{head} base:{MAIN} source:{"c" * 40} '
                                        'release:true asan:false concurrency:false')))

    def comment(self, number, created, body=r.COMMAND, updated=None):
        self.comments[number].append(dict(body=body, created_at=stamp(created), updated_at=stamp(updated or created)))

    def get(self, route):
        suffix = route.removeprefix(f'repos/{p.REPOSITORY}').lstrip('/')
        if not suffix: return copy.deepcopy(self.repo)
        if suffix == 'git/ref/heads/main': return dict(object=dict(sha=MAIN))
        if suffix == 'actions/workflows/ci.yml': return copy.deepcopy(self.workflow)
        if suffix.startswith('pulls/'): return copy.deepcopy(self.prs[int(suffix.split('/')[1])])
        if suffix.startswith('git/commits/'): return copy.deepcopy(self.commits[suffix.rsplit('/', 1)[1]])
        raise AssertionError('Unexpected read: ' + route)

    def pages(self, route, key=None):
        suffix = route.removeprefix(f'repos/{p.REPOSITORY}/')
        if suffix == 'pulls?state=open&base=main':
            return copy.deepcopy([pr for pr in self.prs.values() if pr['state'] == 'open'])
        found = re.fullmatch(r'actions/workflows/ci\.yml/runs\?event=pull_request&head_sha=([0-9a-f]{40})', suffix)
        if found: return copy.deepcopy(self.runs[found[1]])
        found = re.fullmatch(r'issues/([0-9]+)/comments\?since=(.+)', suffix)
        if found:
            return copy.deepcopy([c for c in self.comments[int(found[1])] if c['updated_at'] >= found[2]])
        raise AssertionError('Unexpected pages: ' + route)


class Writer:
    """The secret-holding account; only it may comment."""

    def __init__(self, api, accept=True, lost=False):
        self.api, self.accept, self.lost = api, accept, lost

    def mutate(self, method, route, payload):
        self.api.posts.append((method, route, copy.deepcopy(payload)))
        if self.accept:
            self.api.comment(int(route.rsplit('/', 2)[1]), NOW, payload['body'])
        if self.lost or not self.accept:
            raise OSError('lost reply')


class RebaseTests(unittest.TestCase):
    def plan(self, api):
        return r.plan(api, p, NOW)

    def test_the_oldest_stale_update_is_asked_exactly_once(self):
        api = RebaseAPI()
        target, reason = self.plan(api)
        self.assertEqual(target, dict(pr=71, head=api.prs[71]['head']['sha'], main=MAIN,
                                      committed=datetime(2026, 11, 6, 1, 0, tzinfo=timezone.utc)))
        self.assertIn('PR71', reason)
        self.assertIn('rebase requested', r.request(api, Writer(api), p, target, NOW))
        self.assertEqual(api.posts, [('POST', f'repos/{p.REPOSITORY}/issues/71/comments', {'body': '@dependabot rebase'})])
        # The pending request holds the queue; #73 waits instead of racing it.
        self.assertIsNone(self.plan(api)[0])
        self.assertIn('no longer the next stale update', r.request(api, Writer(api), p, target, NOW))
        self.assertEqual(len(api.posts), 1)

    def test_a_current_update_holds_the_queue_until_its_validation_fails(self):
        for state in [None, ('in_progress', None), ('queued', None), ('completed', 'success')]:
            api = RebaseAPI()
            api.prs[71]['base']['sha'] = MAIN
            if state:
                api.validate(71, *state)
            with self.subTest(state=state):
                target, reason = self.plan(api)
                self.assertIsNone(target)
                self.assertIn('PR71 is the current update', reason)
        for conclusion in ['failure', 'cancelled']:
            api = RebaseAPI()
            api.prs[71]['base']['sha'] = MAIN
            api.validate(71, 'completed', conclusion)
            with self.subTest(conclusion=conclusion):
                self.assertEqual(self.plan(api)[0]['pr'], 73)
        # Only the latest validation bound to this PR head decides.
        api = RebaseAPI()
        api.prs[71]['base']['sha'] = MAIN
        api.validate(71, 'completed', 'failure', 50)
        api.validate(71, 'in_progress', None, 51)
        self.assertIsNone(self.plan(api)[0])
        api = RebaseAPI()
        api.prs[71]['base']['sha'] = MAIN
        api.validate(71, 'completed', 'failure', 50)
        api.runs[api.prs[71]['head']['sha']].append(dict(id=52, run_number=52, workflow_id=10, status='queued',
            conclusion=None, display_title='CI metadata-only v1 pr:71 head:x base:y action:edited source:z'))
        self.assertEqual(self.plan(api)[0]['pr'], 73)

    def test_a_pending_request_holds_and_an_ignored_one_is_never_repeated(self):
        for author_body in [r.COMMAND, '@dependabot recreate', '  @dependabot rebase\n']:
            api = RebaseAPI()
            api.comment(71, NOW - timedelta(minutes=59), author_body)
            with self.subTest(body=author_body):
                target, reason = self.plan(api)
                self.assertIsNone(target)
                self.assertIn('waiting for Dependabot', reason)
        api = RebaseAPI()
        api.comment(71, NOW - timedelta(hours=1))
        self.assertEqual(self.plan(api)[0]['pr'], 73)
        # Requests before the current head, or other text, are not pending work.
        before = datetime(2026, 11, 6, 0, 59, tzinfo=timezone.utc)
        for created, body, updated in [(before, r.COMMAND, None), (before, r.COMMAND, NOW),
                                       (NOW, '@dependabot rebase please', None), (NOW, 'LGTM', None)]:
            api = RebaseAPI()
            api.comment(71, created, body, updated)
            with self.subTest(created=created, body=body):
                self.assertEqual(self.plan(api)[0]['pr'], 71)
        # Dependabot's new head makes the update current; nothing else is asked.
        api = RebaseAPI()
        api.comment(71, NOW - timedelta(minutes=5))
        api.prs[71]['base']['sha'] = MAIN
        api.prs[71]['head']['sha'] = '1' * 40
        api.commits['1' * 40] = dict(sha='1' * 40, committer=dict(date=stamp(NOW)))
        api.runs['1' * 40] = []
        self.assertIn('PR71 is the current update', self.plan(api)[1])

    def test_only_open_same_repository_dependabot_updates_into_main_are_considered(self):
        for change in [lambda a: a.prs[71].update(draft=True), lambda a: a.prs[71].update(user=dict(login='person', id=1, type='User')),
                       lambda a: a.prs[71]['head'].update(repo=dict(id=999)),
                       lambda a: a.prs[71]['base'].update(ref='release')]:
            api = RebaseAPI()
            change(api)
            with self.subTest(change=change):
                self.assertEqual(self.plan(api)[0]['pr'], 73)
        api = RebaseAPI()
        api.add(70, base=MAIN, user=dict(login='person', id=1, type='User'))
        self.assertEqual(self.plan(api)[0]['pr'], 71)
        api = RebaseAPI()
        for number in (71, 73):
            api.prs[number]['base']['sha'] = MAIN
            api.validate(number, 'completed', 'failure')
        self.assertEqual(self.plan(api), (None, 'no stale Dependabot update awaits a rebase'))

    def test_untrusted_evidence_rejects_instead_of_guessing(self):
        for change in [lambda a: a.workflow.update(state='disabled_manually'),
                       lambda a: a.commits[a.prs[71]['head']['sha']]['committer'].update(date='2026-11-06T01:00:00'),
                       lambda a: a.prs[71]['head'].update(sha='not-a-sha'),
                       lambda a: a.repo.update(full_name='fork/InnoFlow')]:
            api = RebaseAPI()
            change(api)
            with self.subTest(change=change), self.assertRaises(p.Rejected):
                self.plan(api)

    def test_a_lost_reply_is_read_back_and_never_sent_twice(self):
        api = RebaseAPI()
        target = self.plan(api)[0]
        with mock.patch('sys.stderr', new_callable=io.StringIO) as stderr:
            self.assertIn('rebase requested', r.request(api, Writer(api, lost=True), p, target, NOW))
        self.assertIn('rebase request raised OSError: lost reply', stderr.getvalue())
        api = RebaseAPI()
        with mock.patch.object(r.time, 'sleep'), mock.patch('sys.stderr', new_callable=io.StringIO), \
                self.assertRaisesRegex(p.Rejected, 'unconfirmed'):
            r.request(api, Writer(api, accept=False), p, target, NOW)
        self.assertEqual(len(api.posts), 1)

    def entry(self, api, environment, writer=None):
        def github(token=None):
            self.tokens.append(token)
            return writer if token == 'rebase-token' else api
        self.tokens = []
        with mock.patch.object(r, 'load', return_value=p), mock.patch.object(p, 'GitHub', side_effect=github), \
                mock.patch.object(r, 'datetime', wraps=datetime) as clock, \
                mock.patch.dict(os.environ, environment, clear=True), \
                mock.patch('sys.stdout', new_callable=io.StringIO) as stdout, mock.patch('sys.stderr', new_callable=io.StringIO):
            clock.now.return_value = NOW
            return r.main(), stdout.getvalue()

    def test_entrypoint_comments_only_with_the_secret_and_trusted_context(self):
        api = RebaseAPI()
        status, output = self.entry(api, dict(TRUSTED, DEPENDABOT_REBASE_TOKEN='rebase-token'), Writer(api))
        self.assertEqual(status, 0)
        self.assertEqual(self.tokens, [None, 'rebase-token'])
        self.assertEqual(len(api.posts), 1)
        api = RebaseAPI()
        status, output = self.entry(api, TRUSTED)
        self.assertEqual((status, api.posts, self.tokens), (0, [], [None]))
        self.assertIn('::notice title=Dependabot rebase needed::', output)
        self.assertIn('PR #71', output)
        for change in [dict(GITHUB_EVENT_NAME='pull_request_target'), dict(GITHUB_EVENT_NAME='pull_request'),
                       dict(GITHUB_REF='refs/heads/unmerged'), dict(GITHUB_WORKFLOW_REF=p.REPOSITORY + '/x.yml@refs/heads/main'),
                       dict(GITHUB_REPOSITORY='fork/InnoFlow')]:
            api = RebaseAPI()
            with self.subTest(change=change):
                status, _ = self.entry(api, dict(TRUSTED, DEPENDABOT_REBASE_TOKEN='rebase-token', **change), Writer(api))
                self.assertEqual((status, api.posts), (1, []))

    def test_workflow_holds_the_secret_only_for_trusted_background_requests(self):
        source = (ROOT / '.github/workflows/dependabot-rebase.yml').read_text()
        self.assertEqual(source.count('secrets.'), 1)
        step = source.split('      - name: Request one serialized Dependabot rebase\n', 1)[1]
        self.assertIn('DEPENDABOT_REBASE_TOKEN: ${{ secrets.DEPENDABOT_REBASE_TOKEN }}', step)
        self.assertIn('run: python3 -B scripts/dependabot-rebase.py', step)
        self.assertNotIn('pull_request', source)
        self.assertIn(r.WORKFLOW_REF, source)


if __name__ == '__main__':
    unittest.main()
