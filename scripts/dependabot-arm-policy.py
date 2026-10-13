#!/usr/bin/env python3
"""Read-only attribution of the coordinator's post-enable native Ready receipt."""
from datetime import datetime
import hashlib
import json
import os
import re

PREFIX = 'Native arm v1 '
GATE_STEP = 'Gate native auto-merge on exact current CI proof'
RECEIPT = re.compile(r'Native arm v1 pr:([1-9][0-9]*) proof:([a-f0-9]{64}) ready:([1-9][0-9]*):([1-9][0-9]*):([1-9][0-9]*):([1-9][0-9]*) request:([a-f0-9]{64}) source:([a-f0-9]{40})')
PROOF_KEYS = ('head', 'base', 'merge', 'run', 'attempt', 'node')
PENDING = {'queued', 'pending', 'waiting', 'requested', 'in_progress'}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def proof_digest(proof):
    return digest({key: proof[key] for key in PROOF_KEYS})


def request_identity(api, p, number, pr):
    data = api.graphql('''query($number:Int!) {
      repository(owner:"InnoSquadCorp",name:"InnoFlow") {
        databaseId nameWithOwner pullRequest(number:$number) {
          id headRefOid autoMergeRequest {
            enabledAt mergeMethod enabledBy { __typename login ... on Bot { databaseId } }
          }
          timelineItems(last:1,itemTypes:[AUTO_MERGE_ENABLED_EVENT,AUTO_MERGE_DISABLED_EVENT,AUTO_REBASE_ENABLED_EVENT,AUTO_SQUASH_ENABLED_EVENT]) {
            nodes { __typename
              ... on AutoMergeEnabledEvent { id createdAt actor { __typename login ... on Bot { databaseId } } }
              ... on AutoMergeDisabledEvent { id createdAt actor { __typename login ... on Bot { databaseId } } }
              ... on AutoRebaseEnabledEvent { id createdAt actor { __typename login ... on Bot { databaseId } } }
              ... on AutoSquashEnabledEvent { id createdAt actor { __typename login ... on Bot { databaseId } } }
            }
          }
        }
      }
    }''', {'number': number})
    repository = data.get('repository') if isinstance(data, dict) else None
    p.require(isinstance(repository, dict) and type(repository.get('databaseId')) is int and
              repository['databaseId'] == pr['base']['repo']['id'] and repository.get('nameWithOwner') == p.REPOSITORY,
              'unverified native request repository')
    graph = repository.get('pullRequest')
    p.require(isinstance(graph, dict) and graph.get('id') == pr['node_id'] and
              graph.get('headRefOid') == pr['head']['sha'], 'native request PR/head changed')
    request = graph.get('autoMergeRequest')
    p.require(isinstance(request, dict) and request.get('mergeMethod') == 'SQUASH', 'native squash request missing')
    actor = request.get('enabledBy')
    p.require(isinstance(actor, dict) and actor.get('__typename') == 'Bot' and
              actor.get('login') == 'github-actions' and type(actor.get('databaseId')) is int and
              actor['databaseId'] == 41898282, 'native request was not armed by GitHub Actions')
    timestamp = request.get('enabledAt')
    p.require(isinstance(timestamp, str), 'native request timestamp missing')
    try:
        parsed = datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    except ValueError:
        raise p.Rejected('malformed native request timestamp') from None
    p.require(parsed.tzinfo is not None, 'native request timestamp lacks timezone')
    events = graph.get('timelineItems', {}).get('nodes', [])
    p.require(len(events) == 1 and isinstance(events[0], dict), 'native request lifecycle event missing')
    event = events[0]
    p.require(event.get('__typename') in {'AutoMergeEnabledEvent', 'AutoSquashEnabledEvent'} and
              isinstance(event.get('id'), str) and bool(event['id']) and
              event.get('actor') == actor, 'native request lifecycle identity changed')
    try:
        event_time = datetime.fromisoformat(event['createdAt'].replace('Z', '+00:00'))
    except (KeyError, ValueError, AttributeError):
        raise p.Rejected('malformed native request event timestamp') from None
    p.require(event_time.tzinfo is not None, 'native request event timestamp lacks timezone')
    # GitHub does not promise equality of request/event timestamps. Bind both,
    # including the unique event ID, rather than assuming they are identical.
    # Event node IDs distinguish disable/re-enable even within one timestamp second.
    return digest(dict(number=number, node=pr['node_id'], head=pr['head']['sha'], base=pr['base']['sha'],
                       merge=pr['merge_commit_sha'], enabledAt=timestamp, event=event['id'], eventCreatedAt=event['createdAt'], mergeMethod=request['mergeMethod'],
                       enabledBy={key: actor[key] for key in ('__typename', 'login', 'databaseId')}))


def failure_barrier(api, p, n, number, head):
    run = n.latest(api, p, number, head)
    job, check, source = n.job_record(api, p, run)
    n.source_compatible(api, p, source)
    p.require(n.controlled_verdict(p, run, job, check) is False, 'controlled native Ready failure required before enable')
    return run['id'], run['run_attempt'], job['id'], check['id']


def writer_source(api, p, n):
    source = os.environ.get('GITHUB_WORKFLOW_SHA', '')
    p.require(os.environ.get('GITHUB_JOB') == 'bot-ready' and bool(p.SHA.fullmatch(source)),
              'receipt requires immutable trusted bot-ready context')
    n.source_compatible(api, p, source)
    return source


def receipt_name(api, p, n, number, proof, barrier):
    source = writer_source(api, p, n)
    request = request_identity(api, p, number, proof['pr'])
    return (f'{PREFIX}pr:{number} proof:{proof_digest(proof)} ready:' + ':'.join(map(str, barrier)) +
            f' request:{request} source:{source}')


def barrier_for_activation(api, p, n, run, number, pr):
    # A completed failure is the only armable barrier. Every activation is its
    # next attempt, in this SAME run. Cancelled/infra failures never qualify.
    if run.get('status') in PENDING:
        p.require(run.get('conclusion') is None, 'pending native activation has terminal conclusion')
    if run.get('status') == 'completed' and run.get('conclusion') == 'failure':
        barrier_run = run
    else:
        p.require(run.get('status') in PENDING or
                  (run.get('status') == 'completed' and run.get('conclusion') == 'success'),
                  'native activation is cancelled or unknown')
        p.require(run['run_attempt'] > 1, 'native activation has no failure predecessor')
        barrier_run = api.get(p.route(f"actions/runs/{run['id']}/attempts/{run['run_attempt'] - 1}"))
        p.require(all(barrier_run.get(key) == run.get(key) for key in
                      ('id', 'workflow_id', 'path', 'head_sha', 'check_suite_id', 'event', 'display_title')) and
                  barrier_run.get('run_attempt') == run['run_attempt'] - 1,
                  'native activation predecessor changed identity')
    n.validate_run(api, p, barrier_run, {'id': run['workflow_id']}, api.get(p.route('')), pr, number, pr['head']['sha'])
    job, check, source = n.job_record(api, p, barrier_run)
    n.source_compatible(api, p, source)
    p.require(n.controlled_verdict(p, barrier_run, job, check) is False, 'activation predecessor is not controlled failure')
    return barrier_run['id'], barrier_run['run_attempt'], job['id'], check['id']


def job_identity(api, p, run, job):
    p.require(job.get('run_id') == run['id'] and job.get('run_attempt') == run['run_attempt'] and
              job.get('head_sha') == run['head_sha'] and type(job.get('id')) is int and job['id'] > 0,
              'receipt job run/attempt/head mismatch')
    prefix = f'https://api.github.com/repos/{p.REPOSITORY}/check-runs/'
    url = job.get('check_run_url', '')
    p.require(url.startswith(prefix) and url[len(prefix):].isdigit(), 'receipt job lacks native check identity')
    identifier = int(url[len(prefix):])
    check = api.get(p.route(f'check-runs/{identifier}'))
    p.require(check.get('id') == identifier and check.get('name') == job.get('name') and
              check.get('app', {}).get('id') == p.APP and check.get('head_sha') == run.get('head_sha') and
              check.get('check_suite', {}).get('id') == run.get('check_suite_id') and
              check.get('details_url') == f"https://github.com/{p.REPOSITORY}/actions/runs/{run['id']}/job/{job['id']}" and
              check.get('status') == job.get('status') == 'completed' and
              check.get('conclusion') == job.get('conclusion') == 'success',
              'unverified successful receipt job/check')


def authenticated_receipt(api, p, n, number, pr, native_run=None, expected_proof=None, writer_run=None):
    """Authenticate metadata only; NEVER call full proof (proof uses this for queues)."""
    head = pr['head']['sha']
    p.require(p.bot(pr) and pr.get('auto_merge') is not None, 'native receipt requires armed verified bot')
    native_run = native_run or n.latest(api, p, number, head)
    barrier = barrier_for_activation(api, p, n, native_run, number, pr)
    request = request_identity(api, p, number, pr)
    workflow = api.get(p.route('actions/workflows/dependabot-auto-merge.yml'))
    p.require(workflow.get('path') == p.COORDINATOR_PATH and workflow.get('state') == 'active', 'receipt workflow inactive')
    # Receipts cannot predate their failure run. Pagination is mandatory.
    created = native_run.get('created_at', '')
    try:
        after = datetime.fromisoformat(created.replace('Z', '+00:00')).date().isoformat()
    except (ValueError, AttributeError):
        raise p.Rejected('native receipt creation date missing') from None
    candidates = api.pages(p.route(f'actions/workflows/dependabot-auto-merge.yml/runs?created=>={after}'), 'workflow_runs')
    # Collect every page, then prefer the newest valid exact receipt. Later
    # no-op wakes do not revoke it; do not repeatedly read older run job history.
    for candidate in sorted(candidates, key=lambda item: (item['id'], item['run_attempt']), reverse=True):
        if writer_run is not None and candidate.get('id') != writer_run:
            continue
        run = api.get(p.route(f"actions/runs/{candidate['id']}"))
        if (run.get('workflow_id') != workflow['id'] or run.get('path', '').split('@')[0] != p.COORDINATOR_PATH or
                run.get('repository', {}).get('id') != pr['base']['repo']['id'] or
                run.get('head_repository', {}).get('id') != pr['base']['repo']['id'] or
                type(run.get('run_attempt')) is not int or run['run_attempt'] <= 0 or
                type(run.get('check_suite_id')) is not int or run.get('id') != candidate['id']):
            continue
        if run.get('event') == 'pull_request_target':
            links = run.get('pull_requests', [])
            if not (run.get('head_sha') == head and [item.get('number') for item in links] == [number] and
                    links[0].get('head', {}).get('sha') == head and links[0].get('base', {}).get('ref') == 'main' and
                    links[0].get('base', {}).get('repo', {}).get('id') == pr['base']['repo']['id']):
                continue
        elif run.get('event') not in {'workflow_run', 'push', 'schedule', 'workflow_dispatch'} or run.get('head_branch') != 'main':
            continue
        jobs = api.pages(p.route(f"actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"), 'jobs')
        bots = [job for job in jobs if job.get('name') == f'bot-ready ({number})']
        inspectors = [job for job in jobs if job.get('name') == 'inspect']
        if len(bots) != 1 or len(inspectors) != 1:
            continue
        job, inspector = bots[0], inspectors[0]
        if job.get('status') != 'completed' or job.get('conclusion') != 'success':
            continue
        steps = job.get('steps') or []
        receipt_steps = [s for s in steps if s.get('name', '').startswith(PREFIX)]
        if len(receipt_steps) != 1:
            continue
        step = receipt_steps[0]
        match = RECEIPT.fullmatch(step.get('name', ''))
        if not match or int(match[1]) != number or tuple(int(match[i]) for i in (3, 4, 5, 6)) != barrier or match[7] != request:
            continue
        if expected_proof is not None and match[2] != proof_digest(expected_proof):
            continue
        source = match[8]
        if run.get('event') != 'pull_request_target' and run.get('head_sha') != source:
            continue
        job_identity(api, p, run, job)
        job_identity(api, p, run, inspector)
        p.require(all(s.get('status') == 'completed' and s.get('conclusion') == 'success' for s in steps),
                  'receipt has failed/pending/skipped execution')
        gates = [s for s in steps if s.get('name') == GATE_STEP]
        p.require(len(gates) == 1 and steps.index(gates[0]) < steps.index(step), 'receipt precedes proof completion')
        suffix = [s.get('name') for s in steps[steps.index(step) + 1:]]
        p.require(suffix in ([], ['Complete job'], ['Post Checkout trusted coordinator only'],
                             ['Post Checkout trusted coordinator only', 'Complete job']),
                  'receipt is not the final executable step')
        sources = [s for s in inspector.get('steps', []) if s.get('name', '').startswith(p.COORDINATOR_SOURCE_STEP)]
        p.require(len(sources) == 1 and sources[0].get('name') == p.COORDINATOR_SOURCE_STEP + source and
                  all(s.get('status') == 'completed' and s.get('conclusion') == 'success' for s in inspector.get('steps', [])),
                  'receipt/inspector trusted source mismatch')
        n.source_compatible(api, p, source)
        return dict(run=run['id'], attempt=run['run_attempt'], job=job['id'], barrier=barrier,
                    proof=match[2], request=request, source=source)
    raise p.Rejected('no trusted post-enable receipt for current native request/activation')
