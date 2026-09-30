import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('legacy', ROOT / 'scripts/legacy-ci-results.py')
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


class LegacyTests(unittest.TestCase):
    def runs(self):
        return [dict(path=path, event='pull_request', head_sha='a'*40, id=i+1,
                     run_attempt=1, created_at='2026-09-30T01:00:00Z', status='completed',
                     conclusion='success', pull_requests=[{'number':55}]) for i,path in enumerate(legacy.LEGACY)]

    def test_only_current_latest_original_workflows_are_accepted(self):
        runs = self.runs()
        self.assertEqual(len(legacy.latest_runs(runs, 'pull_request', 'a'*40, 55)), 7)
        for key,value in [('event','workflow_dispatch'), ('head_sha','b'*40), ('path','.github/workflows/foreign.yml'),
                          ('pull_requests',[{'number':56}]), ('status','queued'), ('conclusion','failure'),
                          ('conclusion','cancelled'), ('conclusion','skipped')]:
            bad = copy.deepcopy(runs)
            bad[0][key] = value
            with self.subTest(key=key,value=value), self.assertRaises(ValueError):
                legacy.latest_runs(bad,'pull_request','a'*40,55)
        later = copy.deepcopy(runs[0])
        later.update(id=100, created_at='2026-09-30T02:00:00Z', conclusion='failure')
        with self.assertRaises(ValueError):
            legacy.latest_runs(runs+[later],'pull_request','a'*40,55)
        later.update(id=runs[0]['id'],created_at=runs[0]['created_at'],run_attempt=2,status='in_progress')
        with self.assertRaises(ValueError):
            legacy.latest_runs(runs+[later],'pull_request','a'*40,55)

    def test_every_child_including_runtime_matrices_must_succeed(self):
        for path,run in legacy.latest_runs(self.runs(),'pull_request','a'*40,55).items():
            jobs=[dict(name=n,run_id=run['id'],run_attempt=1,status='completed',conclusion='skipped' if n=='codecov' else 'success') for n in legacy.LEGACY[path]]
            legacy.validate_jobs(path,run,jobs)
            for job in range(len(jobs)):
                for state in (('failure','success','cancelled',None) if jobs[job]['name']=='codecov' else ('failure','skipped','cancelled',None)):
                    bad=copy.deepcopy(jobs)
                    bad[job]['conclusion']=state
                    with self.assertRaises(ValueError): legacy.validate_jobs(path,run,bad)
            for bad in (jobs[:-1],jobs+[jobs[0]], [dict(jobs[0],run_attempt=2)]+jobs[1:]):
                with self.assertRaises(ValueError): legacy.validate_jobs(path,run,bad)

    def test_check_app_suite_job_and_head_attribution(self):
        run={'id':1,'check_suite_id':2}
        job={'name':'gates','id':3,'conclusion':'success'}
        check={'app':{'id':15368},'name':'gates','check_suite':{'id':2},'head_sha':'a'*40,
               'status':'completed','conclusion':'success',
               'details_url':'https://github.com/InnoSquadCorp/InnoRouter/actions/runs/1/job/3'}
        legacy.validate_check(job,run,check,'a'*40,'b'*40)
        for field,value in [('app',{'id':1}),('check_suite',{'id':9}),('head_sha','c'*40),
                            ('status','in_progress'),('conclusion','failure'),('details_url','https://example.test')]:
            bad=copy.deepcopy(check);bad[field]=value
            with self.assertRaises(ValueError):legacy.validate_check(job,run,bad,'a'*40,'b'*40)

    def test_pagination_includes_second_page_failure(self):
        class Fake(legacy.API):
            def get(self,path):
                return {'jobs': [{'name':str(i),'conclusion':'success'} for i in range(100)]} if '&page=1' in path else {'jobs':[{'name':'late','conclusion':'failure'}]}
        jobs=Fake('InnoSquadCorp/InnoRouter','').pages('repos/x/jobs','jobs')
        self.assertEqual(len(jobs),101)
        self.assertEqual(jobs[-1]['conclusion'],'failure')

    def test_current_pr_rejects_base_head_and_merge_races(self):
        class Fake:
            repo='InnoSquadCorp/InnoRouter'
            def get(self,path):return self.pr
        api=Fake()
        original=dict(state='open',head={'sha':'a'*40},base={'sha':'b'*40,'ref':'main'},merge_commit_sha='c'*40)
        api.pr=copy.deepcopy(original)
        legacy.current_pr(api,55,'a'*40,'b'*40,'c'*40)
        for field in ('head','base','merge_commit_sha','state'):
            api.pr=copy.deepcopy(original)
            if field in ('head','base'):api.pr[field]['sha']='d'*40
            else:api.pr[field]='changed'
            with self.assertRaises(ValueError):legacy.current_pr(api,55,'a'*40,'b'*40,'c'*40)


if __name__=='__main__':unittest.main()
