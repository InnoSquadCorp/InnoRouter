"""Native metadata provenance and legacy/aggregate Ready recovery regressions."""
import copy
import importlib.util
import itertools
import json
from pathlib import Path
import subprocess
import unittest
import test_dependabot_merge as bot

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('metadata',ROOT/'scripts/ci-metadata-policy.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
META,SUITE,SOURCE=9900,9901,'f'*40

class MetadataAPI:
    def __init__(self,active=False,inventory=None):
        self.base=bot.API(active)
        self.run=dict(id=META,run_number=999,run_attempt=1,workflow_id=self.base.workflows['ci.yml']['id'],path=m.PATH,
                      event='pull_request',head_sha=bot.HEAD,repository=self.base.repo,head_repository=self.base.repo,
                      status='completed',conclusion='success',check_suite_id=SUITE,
                      display_title=f'{m.PREFIX}pr:55 head:{bot.HEAD} base:{bot.BASE} action:labeled source:{SOURCE}')
        self.base.runs[META]=self.run
        self.commit=dict(sha=SOURCE,parents=[dict(sha=bot.BASE),dict(sha=bot.HEAD)])
        self.blob=self.expected_blob='9'*40
        self.jobs=[];self.checks=[];self.finish_mutation=None;self.reads=0
        for i,name in enumerate(sorted(m.INVENTORIES[0] if inventory is None else inventory)):
            job=dict(id=20000+i,name=name,run_id=META,run_attempt=1,head_sha=bot.HEAD,status='completed',conclusion='skipped',steps=[],
                     check_run_url=f'https://api.github.com/repos/{bot.REPO}/check-runs/{30000+i}')
            self.jobs.append(job)
            self.checks.append(dict(id=30000+i,name=name,app=dict(id=15368),check_suite=dict(id=SUITE),head_sha=bot.HEAD,
                                    status='completed',conclusion='skipped',details_url=f'https://github.com/{bot.REPO}/actions/runs/{META}/job/{job["id"]}'))
    def get(self,path):
        if path.endswith(f'actions/runs/{META}'):
            self.reads+=1;result=copy.deepcopy(self.run)
            if self.reads%2==0 and self.finish_mutation:self.finish_mutation(result)
            return result
        if path.endswith('git/commits/'+SOURCE):return copy.deepcopy(self.commit)
        if '/contents/'+m.PATH+'?ref=' in path:return dict(sha=self.blob if path.endswith(SOURCE) else self.expected_blob)
        return self.base.get(path)
    def pages(self,path,key=None):
        if f'check-suites/{SUITE}/' in path:return copy.deepcopy(self.checks)
        if f'actions/runs/{META}/attempts/' in path:return copy.deepcopy(self.jobs)
        result=self.base.pages(path,key)
        if f'commits/{bot.HEAD}/check-runs?' in path:result+=copy.deepcopy(self.checks)
        return result
    def graphql(self,*a,**kw):return self.base.graphql(*a,**kw)
    def mutate(self,*a,**kw):return self.base.mutate(*a,**kw)

def yaml(path):return json.loads(subprocess.check_output(['ruby','-ryaml','-rjson','-e','puts YAML.safe_load(File.read(ARGV[0])).to_json',str(path)],text=True))

class MetadataTests(unittest.TestCase):
    def test_inventory_covers_only_exact_skipped_workflow_jobs(self):
        direct=set();calls=[]
        for key,job in yaml(ROOT/m.PATH)['jobs'].items():
            name=job.get('name',key)
            if key=='ci-required':calls.append(({'CI Metadata Only'},{name[4:-3]}))
            elif 'uses' in job:
                children=yaml(ROOT/job['uses'])['jobs']
                calls.append(({name},{name+' / '+v.get('name',k) for k,v in children.items()}))
            else:direct.add(name)
        self.assertEqual({frozenset(x) for x in m.INVENTORIES},{frozenset(direct.union(*x)) for x in itertools.product(*calls)})
    def test_both_rollout_modes_keep_latest_real_validation(self):
        for active in (False,True):
            for inventory in m.INVENTORIES:
                api=MetadataAPI(active,inventory)
                proof=bot.policy.proof(api,55)
                self.assertEqual(proof['run'],100)
                self.assertEqual(api.base.writes,[])
    def test_real_failure_cancellation_or_pending_cannot_be_hidden(self):
        for status,conclusion in [('completed','failure'),('completed','cancelled'),('in_progress',None)]:
            api=MetadataAPI();api.base.runs[100].update(status=status,conclusion=conclusion)
            with self.assertRaises(ValueError):bot.policy.proof(api,55)
    def test_metadata_never_substitutes_for_missing_validation(self):
        api=MetadataAPI();api.base.runs.pop(100)
        with self.assertRaisesRegex(ValueError,'missing workflow'):bot.policy.proof(api,55)
    def test_forged_pending_executed_or_racing_metadata_blocks(self):
        mutations=[lambda a:a.run.update(display_title=m.PREFIX+'forged'),lambda a:a.run.update(workflow_id=999),
                   lambda a:a.run.update(status='in_progress'),lambda a:a.run.update(conclusion='cancelled'),
                   lambda a:a.run.update(head_sha='0'*40),lambda a:a.commit['parents'][0].update(sha='0'*40),
                   lambda a:setattr(a,'blob','0'*40),lambda a:a.jobs.pop(),lambda a:a.jobs.append(a.jobs[0]),
                   lambda a:a.jobs[0].update(name='CI Required'),lambda a:a.jobs[0].update(conclusion='success'),
                   lambda a:a.jobs[0].update(steps=[dict(name='executed')]),lambda a:a.jobs[0].update(run_attempt=2),
                   lambda a:a.jobs[0].update(check_run_url='https://example.invalid/123'),
                   lambda a:a.checks[0]['app'].update(id=999),lambda a:a.checks[0].update(details_url='forged'),
                   lambda a:a.checks.append(a.checks[0]),lambda a:a.run.update(run_attempt=2),
                   lambda a:setattr(a,'finish_mutation',lambda r:r.update(run_attempt=2))]
        for i,mutate in enumerate(mutations):
            api=MetadataAPI();mutate(api)
            with self.subTest(i=i),self.assertRaises(ValueError):bot.policy.proof(api,55)
    def test_valid_metadata_completion_wakes_current_proof(self):
        api=MetadataAPI()
        result=bot.policy.coordinate(api,55,True,dict(id=META,run_attempt=1))
        self.assertIn('native auto-merge armed',result)
        self.assertEqual([x[0] for x in api.base.writes].count('enable'),1)
    def test_unknown_metadata_notification_cancels_prior_approval(self):
        api=MetadataAPI();api.run['status']='in_progress';api.base.pr['auto_merge']={'enabled_at':'before'}
        result=bot.policy.coordinate(api,55,True,dict(id=META,run_attempt=1))
        self.assertIn('blocked:',result);self.assertIsNone(api.base.pr['auto_merge'])
        self.assertNotIn('enable',[x[0] for x in api.base.writes])
    def test_non_pr_ci_does_not_allocate_coordinator(self):
        from test_ci_event_routing import condition,evaluate
        expr=condition((ROOT/'.github/workflows/dependabot-auto-merge.yml').read_text(),'inspect')
        for original in ['push','workflow_dispatch','merge_group','pull_request']:
            values={'github.event_name':'workflow_run','github.event.workflow_run.path':m.PATH,
                    'github.event.workflow_run.event':original,'github.repository':bot.REPO,'github.ref':'refs/heads/main',
                    'github.workflow_ref':bot.REPO+'/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'}
            self.assertEqual(evaluate(expr,values),original=='pull_request')
    def test_ready_transition_reuses_ci_and_labels_match_actions_case_rules(self):
        from test_ci_policy import policy,pr
        triggers=yaml(ROOT/m.PATH)['true']['pull_request']['types']
        self.assertNotIn('ready_for_review',triggers)
        plan=policy.make_plan('pull_request',pr(['RELEASE-VALIDATION']),['README.md'])
        self.assertTrue(all(plan['jobs'].values()))
