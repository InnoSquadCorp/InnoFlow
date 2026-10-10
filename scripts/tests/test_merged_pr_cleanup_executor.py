import copy
import importlib.util
import re
from pathlib import Path
import unittest
import urllib.error
spec=importlib.util.spec_from_file_location('cleanup_executor',Path(__file__).resolve().parents[1]/'merged_pr_cleanup.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class FakeAPI:
 def __init__(self,repo,pr,runs):self.repo=repo;self.pr=pr;self.runs=runs;self.calls=[];self.pages=None;self.mutate=None;self.posts=0;self.failure=None;self.workflow={'id':9,'path':'.github/workflows/ci.yml','state':'active'}
 def request(self,method,path):
  self.calls.append((method,path))
  if self.mutate:self.mutate(self,method,path)
  if method=='POST':
   self.posts+=1
   if self.failure:raise self.failure
   return {}
  if '/pulls/' in path:return copy.deepcopy(self.pr)
  if '/actions/workflows/' in path and '?' not in path:return copy.deepcopy(self.workflow)
  if '?' in path:
   page=int(path.split('page=')[-1]);rows=self.pages[page-1] if self.pages else self.runs
   return {'total_count':sum(map(len,self.pages)) if self.pages else len(self.runs),'workflow_runs':copy.deepcopy(rows)}
  if '/actions/runs/' in path:return copy.deepcopy(next(r for r in self.runs if str(r['id'])==path.rsplit('/',1)[1]))
  return copy.deepcopy(self.repo)
class CleanupExecutorTests(unittest.TestCase):
 repository_name='InnoSquadCorp/InnoFlow'
 def setUp(self):
  self.repo={'full_name':'Org/Repo','id':1,'default_branch':'main'};self.sha='a'*40;source='b'*40
  self.pr={'number':42,'state':'closed','merged':True,'created_at':'2026-01-01T00:00:00Z','merged_at':'2026-01-02T00:00:00Z','head':{'sha':self.sha,'ref':'feature/scoped-ci'},'base':{'repo':{'id':1}}}
  self.event={'action':'closed','number':42,'repository':self.repo,'pull_request':copy.deepcopy(self.pr)}
  self.context={'event_name':'pull_request_target','repository':'Org/Repo','ref':'refs/heads/main','workflow_ref':'Org/Repo/.github/workflows/merged-pr-cleanup.yml@refs/heads/main','source_sha':source,'checkout_sha':source,'enable_writes':'enabled'}
  self.config={'schema':1,'repository':'Org/Repo','status':'reviewed-cleanup-policy-v1','merged_pr_pull_request_workflow_allowlist':['.github/workflows/ci.yml']}
  run={'id':100,'run_attempt':1,'created_at':'2026-01-01T12:00:00Z','run_started_at':'2026-01-01T12:01:00Z','repository':self.repo,'event':'pull_request','status':'queued','conclusion':None,'head_sha':self.sha,'path':'.github/workflows/ci.yml','workflow_id':9,'head_branch':'feature/scoped-ci','pull_requests':[copy.deepcopy(self.pr)]}
  self.api=FakeAPI(self.repo,self.pr,[run])
 def execute(self,apply=False):return m.execute(self.event,self.context,self.config,self.api,apply)
 def test_default_dry_run_only_reads(self):
  result=self.execute();self.assertTrue(result['dry_run']);self.assertEqual(self.api.posts,0);self.assertEqual(len(result['candidates']),1)
 def test_apply_requires_optin_and_fresh_rechecks(self):
  self.context['enable_writes']='';
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.calls,[]);self.context['enable_writes']='enabled';result=self.execute(True)
  self.assertEqual(result['cancellation_requested'],[100]);self.assertEqual(self.api.calls[-3:],[('GET','repos/Org/Repo/pulls/42'),('GET','repos/Org/Repo/actions/runs/100'),('POST','repos/Org/Repo/actions/runs/100/cancel')])
 def test_untrusted_ref_checkout_workflow_never_calls_api(self):
  for key in ['ref','checkout_sha','workflow_ref','event_name']:
   original=self.context[key];self.context[key]='untrusted'
   with self.assertRaises(ValueError):self.execute(True)
   self.context[key]=original;self.assertEqual(self.api.calls,[])
 def test_invalid_or_preserved_workflow_allowlist_never_calls_api(self):
  for allowed,preserved in [([],[]),(['.github/workflows/ci.yml']*2,[]),
                             (['.github/workflows/ci.yml'],['.github/workflows/ci.yml']),
                             ('ci.yml',[]),([None],[])]:
   self.setUp();self.config['merged_pr_pull_request_workflow_allowlist']=allowed
   self.config['always_preserved_workflows']=preserved
   with self.subTest(allowed=allowed),self.assertRaises(ValueError):self.execute(True)
   self.assertEqual(self.api.calls,[])
 def test_foreign_webhook_repository_identity_never_lists_or_cancels(self):
  for identity in [True,2,None]:
   self.setUp();self.event['repository']={**self.repo,'id':identity}
   with self.subTest(identity=identity),self.assertRaises(ValueError):self.execute(True)
   self.assertEqual(self.api.calls,[('GET','repos/Org/Repo')]);self.assertEqual(self.api.posts,0)
 def test_push_and_different_pr_preserved(self):
  run=copy.deepcopy(self.api.runs[0]);run.update(id=101,event='push');self.api.runs.append(run)
  run=copy.deepcopy(self.api.runs[0]);run.update(id=102,pull_requests=[{'number':99}]);self.api.runs.append(run)
  self.assertEqual(self.execute(True)['cancellation_requested'],[100])
 def test_completed_or_new_attempt_at_recheck_is_not_cancelled(self):
  for mutation in [lambda r:r.update(status='completed',conclusion='success'),lambda r:r.update(run_attempt=2)]:
   self.setUp()
   def race(api,method,path):
    if path.endswith('/actions/runs/100'):mutation(api.runs[0])
   self.api.mutate=race;result=self.execute(True);self.assertEqual(self.api.posts,0);self.assertEqual(result['already_finished_or_changed'],[100])
 def test_pr_reopened_or_changed_before_write_rejects(self):
  count=[0]
  def race(api,method,path):
   if '/pulls/' in path:
    count[0]+=1
    if count[0]>1:api.pr['head']['sha']='c'*40
  self.api.mutate=race
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_merge_window_changes_before_write_reject(self):
  for key in ['created_at','merged_at']:
   self.setUp();count=[0]
   def race(api,method,path):
    if '/pulls/' in path:
     count[0]+=1
     if count[0]>1:api.pr[key]='2026-01-01T01:00:00Z'
   self.api.mutate=race
   with self.subTest(key=key),self.assertRaises(ValueError):self.execute(True)
   self.assertEqual(self.api.posts,0)
 def test_closed_unmerged_and_foreign_repo_reject(self):
  self.api.pr['merged']=False
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_inventory_is_scoped_to_allowlisted_workflow_and_pr_branch(self):
  self.execute(True)
  queries=[path for method,path in self.api.calls if '?' in path]
  self.assertEqual(len(queries),1)
  self.assertIn('/actions/workflows/ci.yml/runs?',queries[0])
  self.assertIn('branch=feature%2Fscoped-ci&',queries[0])
  self.assertNotIn('head_sha=',queries[0])
 def test_unrelated_repository_run_volume_cannot_block_scoped_cleanup(self):
  original=self.api.request
  def busy(method,path):
   if '/actions/runs?' in path:return {'total_count':1001,'workflow_runs':[]}
   return original(method,path)
  self.api.request=busy
  self.assertEqual(self.execute(True)['cancellation_requested'],[100])
 def test_missing_authoritative_branch_rejects_before_cancel(self):
  del self.api.pr['head']['ref']
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_pagination_is_collected_before_any_write(self):
  second=copy.deepcopy(self.api.runs[0]);second['id']=101;self.api.runs.append(second);self.api.pages=[[self.api.runs[0]],[second]]
  self.assertEqual(self.execute(True)['cancellation_requested'],[100,101]);self.assertTrue(any('page=2' in path for method,path in self.api.calls))
 def test_previous_head_and_post_merge_rerun_survive(self):
  previous=copy.deepcopy(self.api.runs[0]);previous.update(id=101,head_sha='d'*40);previous['pull_requests'][0]['head']['sha']='d'*40;self.api.runs.append(previous)
  restarted=copy.deepcopy(self.api.runs[0]);restarted.update(id=102,run_attempt=2,run_started_at='2026-01-02T01:00:00Z');self.api.runs.append(restarted)
  self.assertEqual(self.execute(True)['cancellation_requested'],[100])
 def test_missing_merge_or_run_time_cannot_authorize_cancellation(self):
  del self.api.runs[0]['created_at'];self.assertEqual(self.execute(True)['cancellation_requested'],[])
  del self.api.pr['merged_at']
  with self.assertRaises(ValueError):self.execute(True)
 def test_permission_denial_no_retry(self):
  self.api.failure=urllib.error.HTTPError('https://api.github.com',403,'Forbidden',{},None)
  self.addCleanup(self.api.failure.close)
  with self.assertRaises(urllib.error.HTTPError):self.execute(True)
  self.assertEqual(self.api.posts,1)
 def test_unexpected_redirects_are_never_followed(self):
  with self.assertRaises(ValueError):m.NoRedirect().redirect_request(None,None,302,'redirect',{},'https://evil.example')
 def test_truncated_or_capped_inventory_cannot_partially_cancel(self):
  original=self.api.request
  def incomplete(method,path):
   value=original(method,path)
   if '?' in path:value['total_count']=1001
   return value
  self.api.request=incomplete
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_changed_total_or_duplicate_inventory_never_partially_cancels(self):
  original=self.api.request
  def changed(method,path):
   value=original(method,path)
   if '?' in path:value['total_count']=2 if path.endswith('page=1') else 3
   return value
  self.api.request=changed
  with self.assertRaisesRegex(ValueError,'changed during pagination'):self.execute(True)
  self.assertEqual(self.api.posts,0)
  self.setUp();self.api.runs.append(copy.deepcopy(self.api.runs[0]))
  with self.assertRaisesRegex(ValueError,'duplicate run identity'):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_foreign_post_path_forbidden(self):
  api=m.API('Org/Repo','test-token')
  with self.assertRaises(ValueError):api.request('POST','repos/Org/Other/actions/runs/1/cancel')
  with self.assertRaises(ValueError):api.request('POST','repos/Org/Repo/actions/runs/1/rerun')
 def test_workflow_only_dedicated_trusted_job_can_write(self):
  root=Path(__file__).resolve().parents[2];text=(root/'.github/workflows/merged-pr-cleanup.yml').read_text()
  self.assertIn('pull_request_target:',text);self.assertIn('types: [closed]',text);self.assertIn('ref: ${{ github.workflow_sha }}',text)
  self.assertIn('persist-credentials: false',text);self.assertIn('cancel-in-progress: false',text);self.assertIn("CLEANUP_ENABLE_WRITES: 'enabled'",text)
  self.assertNotIn('pull_request.head.ref',text);self.assertNotIn('pull_request.head.sha',text);self.assertNotIn('contents: write',text)
  self.assertEqual(text.count('actions: write'),1)
  self.assertIn('--apply',text);self.assertNotIn('--dry-run',text)
  jobs=text.split('\njobs:\n',1)[1]
  self.assertEqual(re.findall(r'^  ([\w-]+):$',jobs,re.M),['inspect'])
  block=re.search(r'^    permissions:\n((?:^      [\w-]+: \w+\n)+)',jobs,re.M)
  self.assertIsNotNone(block)
  self.assertEqual(dict(re.findall(r'^      ([\w-]+): (\w+)$',block[1],re.M)),{'contents':'read','actions':'write','pull-requests':'read'})
  self.assertEqual(text.split('\njobs:\n',1)[0].split('permissions:\n',1)[1].split('\n\n',1)[0],'  contents: read')
  for guard in ['github.event.pull_request.merged == true',
                "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)",
                "github.workflow_ref == format('{0}/.github/workflows/merged-pr-cleanup.yml@refs/heads/{1}', github.repository, github.event.repository.default_branch)"]:
   self.assertIn(guard,text)
  self.assertIn("github.repository == '"+self.repository_name+"'",text)
  for unsafe in ['secrets.', 'download-artifact', 'cache@', 'pip install', 'npm install', 'continue-on-error']:
   self.assertNotIn(unsafe,text)
  self.assertNotIn('vars.INNO_MERGED_PR_CLEANUP',text)

 def test_only_queued_or_in_progress_exact_head_can_cancel(self):
  for status in ['queued','in_progress','waiting','pending','requested','completed','unknown']:
   self.setUp();self.api.runs[0]['status']=status
   with self.subTest(status=status):
    result=self.execute(True)
    self.assertEqual(result['cancellation_requested'],[100] if status in ('queued','in_progress') else [])
 def test_protected_pr_heads_reject_before_inventory(self):
  for branch in ['main','master','release','release/6.1','releases/6.1','release-6.1','MAIN','production']:
   self.setUp()
   if branch=='production':
    self.repo['default_branch']=branch;self.context['ref']='refs/heads/'+branch
    self.context['workflow_ref']='Org/Repo/.github/workflows/merged-pr-cleanup.yml@refs/heads/'+branch
   self.api.pr['head']['ref']=branch;self.api.runs[0]['head_branch']=branch
   with self.subTest(branch=branch),self.assertRaises(ValueError):self.execute(True)
   self.assertEqual(self.api.posts,0);self.assertFalse(any('?' in path for _,path in self.api.calls))
 def test_foreign_workflow_id_branch_event_or_sha_never_cancels(self):
  cases=[('workflow_id',10),('workflow_id',True),('head_branch','main'),('head_branch','release/6'),
         ('head_branch','other-feature'),('head_branch',None),('head_sha','d'*40),
         ('event','workflow_dispatch'),('event','pull_request_target'),('event','push'),
         ('path','.github/workflows/release.yml')]
  for key,value in cases:
   self.setUp();self.api.runs[0][key]=value
   with self.subTest(key=key,value=value):self.assertEqual(self.execute(True)['cancellation_requested'],[])
 def test_authoritative_workflow_identity_is_required_and_rechecked(self):
  for change in [{'id':True},{'id':0},{'path':'.github/workflows/other.yml'},{'state':'disabled_manually'}]:
   self.setUp();self.api.workflow.update(change)
   with self.subTest(change=change),self.assertRaises(ValueError):self.execute(True)
   self.assertEqual(self.api.posts,0)
  self.setUp();count=[0]
  def race(api,method,path):
   if path.endswith('/actions/workflows/ci.yml'):
    count[0]+=1
    if count[0]>1:api.workflow['id']=10
  self.api.mutate=race
  with self.assertRaisesRegex(ValueError,'workflow identity raced'):self.execute(True)
  self.assertEqual(self.api.posts,0)
 def test_arbitrary_workflow_allowlist_cannot_be_selected(self):
  self.config['merged_pr_pull_request_workflow_allowlist']=['.github/workflows/other.yml']
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.calls,[])
 def test_reopened_unmerged_or_branch_changes_at_recheck_never_cancel(self):
  for change in [lambda pr:pr.update(state='open'),lambda pr:pr.update(merged=False),
                 lambda pr:pr['head'].update(ref='main'),lambda pr:pr['base']['repo'].update(id=2)]:
   self.setUp();count=[0]
   def race(api,method,path):
    if '/pulls/' in path:
     count[0]+=1
     if count[0]>1:change(api.pr)
   self.api.mutate=race
   with self.subTest(change=change),self.assertRaises(ValueError):self.execute(True)
   self.assertEqual(self.api.posts,0)
 def test_fresh_run_identity_or_association_change_never_cancels(self):
  for change in [lambda run:run.update(workflow_id=10),lambda run:run.update(head_branch='release/6'),
                 lambda run:run.update(event='workflow_dispatch'),lambda run:run.update(status='waiting'),
                 lambda run:run['pull_requests'][0].update(number=99),
                 lambda run:run.update(head_sha='c'*40)]:
   self.setUp()
   def race(api,method,path):
    if path.endswith('/actions/runs/100'):change(api.runs[0])
   self.api.mutate=race
   with self.subTest(change=change):self.assertEqual(self.execute(True)['cancellation_requested'],[])
   self.assertEqual(self.api.posts,0)
 def test_read_api_failure_never_falls_back_to_cancellation(self):
  for endpoint in ['/actions/workflows/ci.yml','/pulls/42','/actions/runs/100','/runs?']:
   self.setUp()
   def failure(api,method,path):
    if endpoint in path:
     error=urllib.error.HTTPError('https://api.github.com',403,'Forbidden',{},None)
     self.addCleanup(error.close);raise error
   self.api.mutate=failure
   with self.subTest(endpoint=endpoint),self.assertRaises(urllib.error.HTTPError):self.execute(True)
   self.assertEqual(self.api.posts,0)
 def test_conflict_is_ignored_only_after_completed_recheck(self):
  self.api.failure=urllib.error.HTTPError('https://api.github.com',409,'Conflict',{},None)
  self.addCleanup(self.api.failure.close)
  def finish_after_request(api,method,path):
   if method=='POST':api.runs[0].update(status='completed',conclusion='success')
  self.api.mutate=finish_after_request
  result=self.execute(True)
  self.assertEqual(result['cancellation_requested'],[])
  self.assertEqual(result['already_finished_or_changed'],[100])
  self.assertEqual(self.api.posts,1)
 def test_conflict_with_still_active_run_is_not_silenced(self):
  self.api.failure=urllib.error.HTTPError('https://api.github.com',409,'Conflict',{},None)
  self.addCleanup(self.api.failure.close)
  with self.assertRaises(urllib.error.HTTPError):self.execute(True)
  self.assertEqual(self.api.posts,1)
 def test_reopened_pr_is_rejected_immediately_before_write(self):
  count=[0]
  def reopen(api,method,path):
   if '/pulls/' in path:
    count[0]+=1
    if count[0]>1:api.pr.update(state='open',merged=False)
  self.api.mutate=reopen
  with self.assertRaises(ValueError):self.execute(True)
  self.assertEqual(self.api.posts,0)
if __name__=='__main__':unittest.main()
