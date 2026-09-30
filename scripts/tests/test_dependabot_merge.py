import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
import router_ci_adapter as adapter
spec=importlib.util.spec_from_file_location('merge_policy',ROOT/'scripts/dependabot-merge-policy.py')
policy=importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
REPO=policy.REPOSITORY
HEAD,BASE,MERGE='a'*40,'b'*40,'c'*40


class API:
    def __init__(self,active=False):
        self.repo={'id':123,'full_name':REPO,'default_branch':'main','allow_auto_merge':True,'allow_squash_merge':True}
        self.pr={'number':55,'state':'open','merged':False,'draft':False,'mergeable':True,'user':dict(policy.BOT),
                 'head':{'sha':HEAD,'repo':{'id':123,'full_name':REPO}},
                 'base':{'ref':'main','sha':BASE,'repo':{'id':123,'full_name':REPO}},'merge_commit_sha':MERGE,
                 'requested_reviewers':[],'requested_teams':[],'auto_merge':None}
        self.main=BASE;self.behind=0;self.parents=[BASE,HEAD]
        self.rules=[{'type':'required_status_checks','ruleset_source_type':'Repository','ruleset_source':REPO,'ruleset_id':42,
                     'parameters':{'strict_required_status_checks_policy':True,
                                   'required_status_checks':[{'context':c,'integration_id':15368} for c in ('CI Required',policy.READY)]}}]
        self.ruleset={'enforcement':'active','bypass_actors':[]}
        self.review_list=[];self.threads=[];self.review_decision=None
        self.workflows={};self.runs={};self.jobs={};self.checks=[];self.statuses=[];self.writes=[]
        self.denied=False;self.uncertain=False;self.after_enable=None;self.main_runs=[];self.commit_prs=[]
        self.get_count=0;self.race=None
        expected=dict(adapter.PRIMARY)
        if active:
            for _,(caller,children) in adapter.LEGACY.items():expected.update({caller+' / '+k:v for k,v in children.items()})
        else:expected.update({caller:None for caller,_ in adapter.LEGACY.values()})
        self.add_run('ci.yml',expected,100)
        for i,filename in enumerate(adapter.LEGACY,101):self.workflows[filename]={'id':i+1000,'path':'.github/workflows/'+filename,'state':'active'}
        if not active:
            for i,(filename,(_,children)) in enumerate(adapter.LEGACY.items(),101):self.add_run(filename,children,i)

    def add_run(self,filename,expected,run_id):
        self.workflows[filename]={'id':run_id+1000,'path':'.github/workflows/'+filename,'state':'active'}
        run={'id':run_id,'run_number':run_id,'run_attempt':1,'workflow_id':run_id+1000,'path':'.github/workflows/'+filename,
             'status':'completed','conclusion':'success','event':'pull_request','head_sha':HEAD,
             'repository':{'id':123,'full_name':REPO},'head_repository':{'id':123},'check_suite_id':run_id+2000,
             'pull_requests':[{'number':55,'head':{'sha':HEAD},'base':{'sha':BASE}}]}
        self.runs[run_id]=run;self.jobs[run_id]=[]
        for i,(name,step) in enumerate(expected.items()):
            job_id=run_id*100+i;check_id=job_id+100000
            result='skipped' if step is None else 'success'
            job={'id':job_id,'run_id':run_id,'run_attempt':1,'name':name,'status':'completed','conclusion':result,
                 'check_run_url':f'https://api.github.com/repos/{REPO}/check-runs/{check_id}',
                 'steps':[] if step is None else [{'name':step,'status':'completed','conclusion':'success'}]}
            self.jobs[run_id].append(job)
            self.checks.append({'id':check_id,'name':name,'head_sha':HEAD,'app':{'id':15368},
                                'check_suite':{'id':run['check_suite_id']},'status':'completed','conclusion':result,
                                'details_url':f'https://github.com/{REPO}/actions/runs/{run_id}/job/{job_id}'})

    def suffix(self,path):
        if path==f'repos/{REPO}':return ''
        if path.startswith(f'repos/{REPO}/'):return path[len(f'repos/{REPO}/'):]
        raise AssertionError('foreign API target '+path)

    def get(self,path):
        self.get_count+=1
        if self.race:self.race(self,path)
        p=self.suffix(path)
        if not p:return copy.deepcopy(self.repo)
        if p=='pulls/55':return copy.deepcopy(self.pr)
        if p=='git/ref/heads/main':return {'object':{'sha':self.main}}
        if p.startswith('git/commits/'):return {'parents':[{'sha':x} for x in self.parents]}
        if p.startswith('compare/'):return {'behind_by':self.behind,'status':'ahead'}
        if p=='rulesets/42':return self.ruleset
        if p.startswith('actions/workflows/'):return self.workflows[p.split('/')[-1]]
        if p.startswith('actions/runs/'):return copy.deepcopy(self.runs[int(p.split('/')[2])])
        if p.startswith('actions/jobs/'):
            return copy.deepcopy(next(j for jobs in self.jobs.values() for j in jobs if j['id']==int(p.split('/')[-1])))
        raise AssertionError('unhandled GET '+p)

    def pages(self,path,key=None):
        p=self.suffix(path)
        if p=='rules/branches/main':return copy.deepcopy(self.rules)
        if p=='pulls/55/reviews':return copy.deepcopy(self.review_list)
        if p.startswith('actions/workflows/') and '/runs?' in p:
            if 'branch=main' in p:return copy.deepcopy(self.main_runs)
            filename=p.split('/')[2]
            return copy.deepcopy([r for r in self.runs.values() if r['path']=='.github/workflows/'+filename])
        if p.startswith('actions/runs/') and '/jobs' in p:
            run_id=int(p.split('/')[2]);return copy.deepcopy(self.jobs[run_id])
        if p.startswith('commits/') and '/check-runs?' in p:
            sha=p.split('/')[1];return copy.deepcopy([c for c in self.checks if c['head_sha']==sha])
        if p.startswith('commits/') and p.endswith('/statuses'):return copy.deepcopy(self.statuses)
        if p.startswith('commits/') and p.endswith('/pulls'):return copy.deepcopy(self.commit_prs)
        if p.startswith('pulls?'):return [copy.deepcopy(self.pr)]
        raise AssertionError('unhandled pages '+p)

    def graphql(self,query,variables):
        if 'enablePullRequestAutoMerge' in query:
            self.writes.append(('enable',variables))
            if self.denied:raise PermissionError('permission denied')
            self.pr['auto_merge']={'enabled_at':'now'}
            if self.after_enable:self.after_enable(self)
            if self.uncertain:raise TimeoutError('unknown outcome')
            return {'enablePullRequestAutoMerge':{'pullRequest':{'id':'PR_node','headRefOid':HEAD,'autoMergeRequest':{'enabledAt':'now'}}}}
        return {'repository':{'pullRequest':{'id':'PR_node','headRefOid':self.pr['head']['sha'],
                                            'reviewDecision':self.review_decision,
                                            'reviewThreads':{'nodes':self.threads,'pageInfo':{'hasNextPage':False,'endCursor':None}}}}}

    def mutate(self,method,path,payload):
        p=self.suffix(path);self.writes.append((method,p,copy.deepcopy(payload)))
        if p=='check-runs':
            result=copy.deepcopy(payload);result.update(id=999999,app={'id':15368});self.checks.append(result);return result
        if p.startswith('check-runs/'):
            check=next(c for c in self.checks if c['id']==int(p.split('/')[-1]));check.update(payload);return check
        if p=='actions/workflows/ci.yml/dispatches':
            if self.denied:raise PermissionError('permission denied')
            return None
        raise AssertionError('unhandled mutation '+p)


class DependabotTests(unittest.TestCase):
    def assert_rejected(self,api):
        with self.assertRaises((policy.Rejected,KeyError)):policy.proof(api,55)
        self.assertFalse(any(x[0]=='enable' for x in api.writes))

    def test_full_transition_and_active_evidence_pass(self):
        for active in (False,True):
            result=policy.proof(API(active),55)
            self.assertEqual(result['head'],HEAD)
            self.assertTrue(result['evidence'])

    def test_native_enable_uses_head_cas_and_never_direct_merge(self):
        for active in (False,True):
            api=API(active);result=policy.coordinate(api,55,True)
            self.assertIn('armed',result)
            self.assertEqual([x for x in api.writes if x[0]=='enable'],[('enable',{'id':'PR_node','head':HEAD})])
            self.assertEqual(api.checks[-1]['conclusion'],'success')
            self.assertNotIn('mergePullRequest',(ROOT/'scripts/dependabot-merge-policy.py').read_text())

    def test_human_and_spoofed_bot_author_never_auto_merge(self):
        for user in ({'login':'human','id':1,'type':'User'}, {'login':'dependabot[bot]','id':1,'type':'Bot'},
                     {'login':'dependabot[bot]','id':49699333,'type':'User'}):
            api=API();api.pr['user']=user;api.pr['labels']=[{'name':'dependencies'}]
            self.assertIn('manual',policy.coordinate(api,55,True))
            self.assertFalse(any(x[0]=='enable' for x in api.writes))

    def test_fork_base_draft_conflict_and_closed_reject(self):
        for mutate in (lambda p:p['head']['repo'].update(id=9),lambda p:p['base'].update(ref='develop'),
                       lambda p:p.update(draft=True),lambda p:p.update(mergeable=False),lambda p:p.update(state='closed')):
            api=API();mutate(api.pr);self.assert_rejected(api)

    def test_disabled_auto_merge_protection_wrong_app_and_bypass_reject(self):
        for mutate in (lambda a:a.repo.update(allow_auto_merge=False),lambda a:a.repo.update(allow_squash_merge=False),
                       lambda a:a.rules[0]['parameters'].update(strict_required_status_checks_policy=False),
                       lambda a:a.rules[0]['parameters']['required_status_checks'][0].update(integration_id=7),
                       lambda a:a.ruleset.update(bypass_actors=[{'actor_id':1}]),
                       lambda a:a.rules[0]['parameters'].update(required_status_checks=[])):
            api=API();mutate(api);self.assert_rejected(api)
        api=API();self.assertIn('standby',policy.coordinate(api,55,False));self.assertFalse(any(x[0]=='enable' for x in api.writes))

    def test_major_and_swiftsyntax_are_not_excluded(self):
        for title in ('chore(deps): bump swift-syntax to 604.0.0','chore(ci): bump action from 7 to 8'):
            api=API();api.pr.update(title=title,labels=[]);self.assertEqual(policy.proof(api,55)['head'],HEAD)

    def test_latest_attempt_failure_pending_and_obsolete_notification_reject(self):
        for result in ('failure','cancelled','skipped',None):
            api=API();api.runs[100]['run_attempt']=2;api.runs[100]['conclusion']=result;self.assert_rejected(api)
        api=API();api.runs[100]['status']='in_progress';self.assert_rejected(api)
        api=API();api.runs[100]['run_attempt']=2
        self.assertIn('obsolete',policy.coordinate(api,55,True,{'id':100,'run_attempt':1}))
        self.assertFalse(api.writes)

    def test_wrong_workflow_event_origin_and_pr_connection_reject(self):
        for field,value in [('event','workflow_dispatch'),('head_sha','d'*40),('workflow_id',999),
                            ('path','.github/workflows/other.yml'),('head_repository',{'id':999}),('pull_requests',[])]:
            api=API();api.runs[100][field]=value;self.assert_rejected(api)
        api=API();api.runs[100]['pull_requests'][0]['base']['sha']='d'*40;self.assert_rejected(api)

    def test_missing_duplicate_partial_and_skipped_core_jobs_reject(self):
        for active in (False,True):
            for transform in (lambda jobs:jobs.pop(),lambda jobs:jobs.append(copy.deepcopy(jobs[0])),
                              lambda jobs:jobs[0].update(conclusion='skipped'),lambda jobs:jobs[0].update(steps=[])):
                api=API(active);transform(api.jobs[100]);self.assert_rejected(api)
        api=API();api.jobs[101][0]['conclusion']='failure';self.assert_rejected(api)

    def test_check_app_suite_head_job_and_second_page_failure_reject(self):
        for field,value in [('app',{'id':7}),('check_suite',{'id':0}),('head_sha','d'*40),
                            ('details_url','https://example.test/'),('status','queued'),('conclusion','skipped')]:
            api=API();api.checks[0][field]=value;self.assert_rejected(api)
        api=API();api.checks.append({'id':900000,'name':'page-two-failure','app':{'id':999},'head_sha':HEAD,
                                    'status':'completed','conclusion':'failure','details_url':'https://example.test'})
        self.assert_rejected(api)

    def test_review_requests_threads_and_changes_block(self):
        for mutate in (lambda a:a.pr.update(requested_reviewers=[{'id':1}]),lambda a:a.pr.update(requested_teams=[{'id':2}]),
                       lambda a:a.threads.append({'isResolved':False}),lambda a:setattr(a,'review_decision','REVIEW_REQUIRED'),
                       lambda a:a.review_list.append({'id':1,'state':'CHANGES_REQUESTED','user':{'id':1}})):
            api=API();mutate(api);self.assert_rejected(api)

    def test_base_head_test_merge_and_enable_races_block(self):
        for mutate in (lambda a:setattr(a,'main','d'*40),lambda a:setattr(a,'behind',1),
                       lambda a:setattr(a,'parents',[BASE,'d'*40])):
            api=API();mutate(api);self.assert_rejected(api)
        for mutate in (lambda a:a.pr['head'].update(sha='d'*40),lambda a:setattr(a,'main','d'*40),
                       lambda a:a.runs[101].update(run_attempt=2)):
            api=API();api.after_enable=mutate
            self.assertIn('blocked',policy.coordinate(api,55,True))
            self.assertEqual(api.checks[-1]['conclusion'],'failure')

    def test_permission_denial_and_unknown_enable_have_no_blind_retry(self):
        api=API();api.denied=True;self.assertIn('blocked',policy.coordinate(api,55,True))
        self.assertEqual(len([x for x in api.writes if x[0]=='enable']),1)
        api=API();api.uncertain=True;self.assertIn('armed',policy.coordinate(api,55,True))
        self.assertEqual(len([x for x in api.writes if x[0]=='enable']),1)

    def test_post_merge_dispatch_requires_actual_bot_and_current_main(self):
        api=API();api.pr.update(state='closed',merged=True,merged_at='now');api.main=MERGE;api.commit_prs=[api.pr]
        self.assertEqual(policy.verify_post_merge(api,55,MERGE)['number'],55)
        self.assertIn('dispatched',policy.post_merge(api,True))
        self.assertEqual(api.writes[-1],('POST','actions/workflows/ci.yml/dispatches',{'ref':'main','inputs':{'dependabot_merge_pr':'55'}}))
        api.main_runs=[{'head_sha':MERGE,'event':'push'}];before=len(api.writes)
        self.assertIn('already exists',policy.post_merge(api,True));self.assertEqual(len(api.writes),before)
        api.main='d'*40
        with self.assertRaises(policy.Rejected):policy.verify_post_merge(api,55,MERGE)
        api.pr['user']={'login':'human','id':1,'type':'User'}
        with self.assertRaises(policy.Rejected):policy.verify_post_merge(api,55,api.main)

    def test_paginated_api_reads_all_pages_and_rejects_truncation(self):
        class Fake(policy.GitHub):
            def __init__(self):pass
            def request(self,method,path,payload=None):
                if path.endswith('page=1'):return {'check_runs':[{'id':i} for i in range(100)],'total_count':101},{'Link':'<next>; rel="next"'}
                return {'check_runs':[{'id':100,'conclusion':'failure'}],'total_count':101},{}
        values=Fake().pages(policy.route('commits/'+HEAD+'/check-runs'),'check_runs')
        self.assertEqual(len(values),101);self.assertEqual(values[-1]['conclusion'],'failure')

    def test_privileged_workflow_executes_trusted_api_only_code(self):
        source=(ROOT/'.github/workflows/dependabot-auto-merge.yml').read_text()
        self.assertIn('ref: ${{ github.workflow_sha }}',source)
        self.assertIn('sparse-checkout: scripts',source)
        self.assertIn('persist-credentials: false',source)
        self.assertNotIn('github.event.pull_request.head.sha',source)
        self.assertNotIn('download-artifact',source)
        self.assertNotIn('secrets.',source)
        self.assertNotIn('pip install',source)
        self.assertNotIn('npm ',source)
        self.assertIn('checks: write',source)
        self.assertIn('actions: write',source)
        self.assertNotIn('required_approving_review_count',source)


if __name__=='__main__':unittest.main()
