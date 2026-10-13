"""Offline regression proofs for native policy and optional review alignment."""
import copy
import unittest

from test_dependabot_merge_policy import BASE, HEAD, MERGE, NUMBER, RUN, Transcript, p


class AlignmentTranscript(Transcript):
    """Add repository GraphQL metadata without bypassing the existing proof API."""

    def __init__(self):
        super().__init__()
        self.merge_settings = dict(repository=dict(
            databaseId=self.repo['id'], nameWithOwner=p.REPOSITORY,
            autoMergeAllowed=True, squashMergeAllowed=True))
        self.merge_settings_queries = []
        self.merge_parents = [dict(sha=BASE), dict(sha=HEAD)]

    def graphql(self, query, variables):
        if 'autoMergeAllowed' in query:
            self.merge_settings_queries.append((query, copy.deepcopy(variables)))
            if not query.lstrip().startswith('query'):
                raise AssertionError('Repository merge settings must be read-only')
            if 'squashMergeAllowed' not in query:
                raise AssertionError('Both native merge settings must be queried')
            return copy.deepcopy(self.merge_settings)
        return super().graphql(query, variables)

    def get(self, route):
        if route == p.route(f'git/commits/{MERGE}'):
            self.reads.append(route)
            return dict(parents=copy.deepcopy(self.merge_parents))
        return super().get(route)


class DependabotPolicyAlignmentTests(unittest.TestCase):
    REST_SETTINGS = ('allow_auto_merge', 'allow_squash_merge')
    OMISSIONS = (('allow_auto_merge',), ('allow_squash_merge',), REST_SETTINGS)
    REQUESTS = ('reviewer', 'team', 'both')
    STRICTNESS = 'strict_required_status_checks_policy'

    def transcript(self, strict=True, requests=None):
        api = AlignmentTranscript()
        api.rules[0]['parameters'][self.STRICTNESS] = strict
        if requests in ('reviewer', 'both'):
            api.pr['requested_reviewers'] = [dict(id=3, login='reviewer', type='User')]
        if requests in ('team', 'both'):
            api.pr['requested_teams'] = [dict(id=4, slug='maintainers')]
        return api

    def assert_allowed(self, api):
        before = copy.deepcopy(api.pr)
        proof = p.proof(api, NUMBER)
        self.assertEqual(
            (proof['head'], proof['base'], proof['merge'], proof['run'], proof['attempt']),
            (HEAD, BASE, MERGE, RUN, 1))
        self.assertEqual(api.pr, before, 'Proof must not edit optional review requests or the PR')
        self.assertEqual(api.mutations, [])

    def assert_denied(self, api, reason):
        before = copy.deepcopy(api.pr)
        with self.assertRaisesRegex(p.Rejected, reason):
            p.proof(api, NUMBER)
        self.assertEqual(api.pr, before)
        self.assertEqual(api.mutations, [])

    def test_present_true_rest_settings_do_not_query_graphql_fallback(self):
        for strict in (False, True):
            with self.subTest(strict=strict):
                api = self.transcript(strict, 'both')
                api.merge_settings = None  # A fallback would reject this passing control.
                self.assert_allowed(api)
                self.assertEqual(api.merge_settings_queries, [])

    def test_only_omitted_rest_settings_use_identity_bound_graphql_fallback(self):
        for strict in (False, True):
            for omitted in self.OMISSIONS:
                with self.subTest(strict=strict, omitted=omitted):
                    api = self.transcript(strict, 'both')
                    for field in omitted:
                        del api.repo[field]
                    self.assert_allowed(api)
                    self.assertEqual(len(api.merge_settings_queries), 1)
                    query, variables = api.merge_settings_queries[0]
                    self.assertIn('repository(owner:"InnoSquadCorp",name:"InnoFlow")', query)
                    self.assertIn('databaseId', query)
                    self.assertIn('nameWithOwner', query)
                    self.assertEqual(variables, {})

    def test_graphql_fallback_rejects_absent_or_malformed_repository(self):
        for omitted in self.OMISSIONS:
            for response in (None, [], {}, dict(repository=None), dict(repository=[])):
                with self.subTest(omitted=omitted, response=response):
                    api = self.transcript(False, 'both')
                    for field in omitted:
                        del api.repo[field]
                    api.merge_settings = response
                    self.assert_denied(api, 'unverified repository merge settings')
                    self.assertEqual(len(api.merge_settings_queries), 1)

    def test_graphql_fallback_requires_exact_repository_id_name_and_boolean_settings(self):
        changes = [
            ('databaseId', value, 'unverified repository merge settings')
            for value in (None, 101, '100', 100.0, True, False)
        ] + [
            ('nameWithOwner', value, 'unverified repository merge settings')
            for value in (None, 'InnoSquadCorp/Other', 'Other/InnoFlow', 100)
        ] + [
            (field, value, 'native auto-merge/squash feature disabled or unknown')
            for field in ('autoMergeAllowed', 'squashMergeAllowed')
            for value in (False, None, 0, 1, 'true', 'false', [], {})
        ]
        for omitted in self.OMISSIONS:
            for field, value, reason in changes:
                with self.subTest(omitted=omitted, field=field, value=value):
                    api = self.transcript(False, 'both')
                    for rest_field in omitted:
                        del api.repo[rest_field]
                    api.merge_settings['repository'][field] = value
                    self.assert_denied(api, reason)
                    self.assertEqual(len(api.merge_settings_queries), 1)
        for field in ('databaseId', 'nameWithOwner', 'autoMergeAllowed', 'squashMergeAllowed'):
            with self.subTest(missing_graphql_field=field):
                api = self.transcript(False, 'both')
                for rest_field in self.REST_SETTINGS:
                    del api.repo[rest_field]
                del api.merge_settings['repository'][field]
                self.assert_denied(api, 'unverified repository merge settings|disabled or unknown')
                self.assertEqual(len(api.merge_settings_queries), 1)

    def test_explicit_false_or_malformed_rest_never_uses_fallback(self):
        for field in self.REST_SETTINGS:
            other = next(item for item in self.REST_SETTINGS if item != field)
            for value in (False, None, 0, 1, 'true', 'false', [], {}):
                for omit_other in (False, True):
                    with self.subTest(field=field, value=value, omit_other=omit_other):
                        api = self.transcript(False, 'both')
                        api.repo[field] = value
                        if omit_other:
                            del api.repo[other]
                        self.assert_denied(api, 'native auto-merge/squash feature disabled|malformed native merge setting')
                        self.assertEqual(api.merge_settings_queries, [])

    def test_native_strictness_must_be_an_explicit_boolean(self):
        for value in (None, 0, 1, 'false', 'true', [], {}):
            with self.subTest(value=value):
                self.assert_denied(self.transcript(value, 'both'), 'missing or malformed native CI strictness')
        api = self.transcript(False, 'both')
        del api.rules[0]['parameters'][self.STRICTNESS]
        self.assert_denied(api, 'missing or malformed native CI strictness')

    def test_optional_reviewer_team_and_combined_requests_are_preserved(self):
        for strict in (False, True):
            for requests in self.REQUESTS:
                with self.subTest(strict=strict, requests=requests):
                    self.assert_allowed(self.transcript(strict, requests))

    def test_optional_requests_do_not_waive_actual_review_barriers(self):
        changes = [
            ('pending review', lambda a: a.review_list.append(dict(id=1, user=dict(id=3), state='PENDING')),
             'review blocks auto-merge'),
            ('changes requested', lambda a: a.review_list.append(dict(id=1, user=dict(id=3), state='CHANGES_REQUESTED')),
             'review blocks auto-merge'),
            ('unresolved thread', lambda a: a.threads.append(dict(isResolved=False)), 'unresolved review thread'),
            ('unknown resolution', lambda a: a.threads.append(dict(isResolved=None)), 'unresolved review thread'),
            ('native changes requested', lambda a: setattr(a, 'review_decision', 'CHANGES_REQUESTED'),
             'native review decision blocks'),
            ('native approval required', lambda a: setattr(a, 'review_decision', 'REVIEW_REQUIRED'),
             'native review decision blocks'),
        ]
        for strict in (False, True):
            for requests in self.REQUESTS:
                for label, change, reason in changes:
                    with self.subTest(strict=strict, requests=requests, barrier=label):
                        api = self.transcript(strict, requests)
                        if label == 'native approval required':
                            api.rules[-1]['parameters']['required_approving_review_count'] = 1
                        change(api)
                        self.assert_denied(api, reason)

    def test_optional_requests_preserve_satisfied_native_approval_requirement(self):
        for strict in (False, True):
            api = self.transcript(strict, 'both')
            api.rules[-1]['parameters']['required_approving_review_count'] = 1
            api.review_list = [dict(id=1, user=dict(id=3), state='APPROVED')]
            api.review_decision = 'APPROVED'
            api.threads = [dict(isResolved=True)]
            with self.subTest(strict=strict):
                self.assert_allowed(api)

    def test_relaxed_strictness_and_optional_requests_preserve_identity_and_ci_proof(self):
        stale = 'd' * 40
        changes = [
            ('wrong bot login', lambda a: a.pr['user'].update(login='human'), 'not verified Dependabot'),
            ('wrong bot id', lambda a: a.pr['user'].update(id=123), 'not verified Dependabot'),
            ('wrong bot type', lambda a: a.pr['user'].update(type='User'), 'not verified Dependabot'),
            ('fork head', lambda a: a.pr['head'].update(repo=dict(id=101, full_name=p.REPOSITORY)), 'fork or missing head'),
            ('wrong base branch', lambda a: a.pr['base'].update(ref='develop'), 'wrong base branch'),
            ('main advanced', lambda a: setattr(a, 'base', stale), 'base is no longer main'),
            ('stale PR base', lambda a: a.pr['base'].update(sha=stale), 'base is no longer main'),
            ('missing merge SHA', lambda a: a.pr.update(merge_commit_sha=None), 'missing test-merge SHA'),
            ('stale merge base', lambda a: a.merge_parents[0].update(sha=stale), 'test-merge parents'),
            ('stale merge head', lambda a: a.merge_parents[1].update(sha=stale), 'test-merge parents'),
            ('reversed merge parents', lambda a: a.merge_parents.reverse(), 'test-merge parents'),
            ('head changed', lambda a: a.pr['head'].update(sha=stale), 'test-merge parents'),
            ('review head raced', lambda a: setattr(a, 'graph_head', stale), 'head raced during reviews'),
            ('CI base stale', lambda a: a.run['pull_requests'][0]['base'].update(sha=stale), 'obsolete head/base'),
            ('CI connection head stale', lambda a: a.run['pull_requests'][0]['head'].update(sha=stale), 'obsolete head/base'),
            ('CI head stale', lambda a: a.run.update(head_sha=stale), 'wrong CI origin/head'),
            ('CI foreign head repository', lambda a: a.run.update(head_repository=dict(id=101)), 'wrong CI origin/head'),
            ('CI foreign repository', lambda a: a.run.update(repository=dict(id=101)), 'wrong CI origin/head'),
            ('CI wrong event', lambda a: a.run.update(event='push'), 'wrong CI origin/head'),
            ('CI wrong workflow', lambda a: a.run.update(workflow_id=11), 'wrong source workflow identity'),
            ('CI wrong path', lambda a: a.run.update(path='.github/workflows/other.yml'), 'wrong source workflow identity'),
            ('CI ambiguous PR', lambda a: a.run.update(pull_requests=[]), 'missing/ambiguous current PR connection'),
            ('CI absent', lambda a: a.runs.clear(), 'missing exact-head CI'),
            ('CI pending', lambda a: a.run.update(status='in_progress', conclusion=None), 'latest CI incomplete or failed'),
            ('CI failed', lambda a: a.run.update(conclusion='failure'), 'latest CI incomplete or failed'),
            ('CI missing job', lambda a: a.jobs.pop(), 'missing, duplicate or unexpected full CI job'),
            ('CI check wrong app', lambda a: a.checks[0]['app'].update(id=123), 'wrong app/suite/job/head proof'),
            ('CI check wrong suite', lambda a: a.checks[0]['check_suite'].update(id=123), 'wrong app/suite/job/head proof'),
            ('CI check wrong SHA', lambda a: a.checks[0].update(head_sha=BASE), 'wrong app/suite/job/head proof'),
            ('CI check wrong job', lambda a: a.checks[0].update(details_url='https://example.invalid/job/1'),
             'wrong app/suite/job/head proof'),
        ]
        for strict in (False, True):
            for requests in self.REQUESTS:
                for label, change, reason in changes:
                    with self.subTest(strict=strict, requests=requests, control=label):
                        api = self.transcript(strict, requests)
                        change(api)
                        self.assert_denied(api, reason)


if __name__ == '__main__':
    unittest.main()
