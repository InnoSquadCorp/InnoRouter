import copy
import importlib.util
import io
from pathlib import Path
import re
import unittest
from unittest import mock

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

    def test_later_failure_is_not_hidden_by_an_earlier_queued_workflow(self):
        runs = self.runs()
        runs[0].update(status='queued', conclusion=None)
        for conclusion in ['failure', 'cancelled', 'skipped']:
            with self.subTest(conclusion=conclusion):
                runs[-1]['conclusion'] = conclusion
                with self.assertRaisesRegex(ValueError, 'failed/cancelled/skipped'):
                    legacy.latest_runs(runs, 'pull_request', 'a' * 40, 55)


class QueueTranscript:
    """Real validation contract with a virtual runner queue; never sleeps."""
    repo = 'InnoSquadCorp/InnoRouter'

    def __init__(self, ready_at):
        self.now = 0
        self.ready_at = ready_at
        self.sleeps = []
        self.pr = dict(state='open', head=dict(sha='a' * 40),
                       base=dict(sha='b' * 40, ref='main'), merge_commit_sha='c' * 40)
        self.runs = LegacyTests().runs()
        self.jobs, self.checks = {}, {}
        for run in self.runs:
            run['pull_requests'] = [dict(number=55, head=self.pr['head'], base=self.pr['base'])]
            run['check_suite_id'] = run['id'] + 100
            jobs = []
            for index, name in enumerate(legacy.LEGACY[run['path']]):
                job_id = run['id'] * 100 + index
                conclusion = 'skipped' if name == 'codecov' else 'success'
                job = dict(id=job_id, name=name, run_id=run['id'], run_attempt=1,
                           status='completed', conclusion=conclusion,
                           check_run_url=f'https://api.github.com/repos/{self.repo}/check-runs/{job_id}')
                jobs.append(job)
                self.checks[job_id] = dict(app=dict(id=15368), name=name,
                    check_suite=dict(id=run['check_suite_id']), head_sha='c' * 40,
                    status='completed', conclusion=conclusion,
                    details_url=f'https://github.com/{self.repo}/actions/runs/{run["id"]}/job/{job_id}')
            self.jobs[run['id']] = jobs

    def get(self, path):
        if '/pulls/' in path: return copy.deepcopy(self.pr)
        return copy.deepcopy(self.checks[int(path.rsplit('/', 1)[1])])

    def pages(self, path, key):
        if key == 'workflow_runs':
            runs = copy.deepcopy(self.runs)
            if self.now < self.ready_at: runs[-1].update(status='in_progress', conclusion=None)
            return runs
        return copy.deepcopy(self.jobs[int(path.split('/actions/runs/')[1].split('/')[0])])

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def execute(self, *extra):
        argv = ['legacy-ci-results.py', '--event', 'pull_request', '--sha', 'a' * 40,
                '--number', '55', '--base', 'b' * 40, '--merge', 'c' * 40, *extra]
        with mock.patch.object(legacy, 'API', return_value=self), mock.patch('sys.argv', argv), \
                mock.patch.dict('os.environ', GITHUB_REPOSITORY=self.repo, GH_TOKEN='fixture'), \
                mock.patch.object(legacy.time, 'monotonic', side_effect=lambda: self.now), \
                mock.patch.object(legacy.time, 'sleep', side_effect=self.sleep), \
                mock.patch('sys.stdout', new_callable=io.StringIO), \
                mock.patch('sys.stderr', new_callable=io.StringIO) as error:
            return legacy.main(), error.getvalue()


class QueueBudgetTests(unittest.TestCase):
    def test_valid_late_platform_completion_survives_old_110_minute_limit(self):
        t = QueueTranscript(ready_at=7100)
        self.assertEqual(t.execute(), (0, ''))
        self.assertGreaterEqual(t.now, 7100)
        self.assertLess(len(t.sleeps), 70, 'runner queue polling should back off')

    def test_normal_completion_has_no_wait(self):
        t = QueueTranscript(ready_at=0)
        self.assertEqual(t.execute(), (0, ''))
        self.assertEqual(t.sleeps, [])

    def test_unfinished_validation_still_times_out_at_the_explicit_budget(self):
        t = QueueTranscript(ready_at=99999)
        result, error = t.execute('--timeout', '65')
        self.assertEqual(result, 1)
        self.assertIn('timed out waiting for legacy CI', error)
        self.assertEqual(t.now, 65, 'backoff must not oversleep the remaining budget')

    def test_pr_change_during_wait_is_rejected_without_more_sleep(self):
        t = QueueTranscript(ready_at=7100)
        original_sleep = t.sleep
        def move_pr(seconds):
            original_sleep(seconds)
            t.pr['head']['sha'] = 'd' * 40
        t.sleep = move_pr
        result, error = t.execute()
        self.assertEqual(result, 1)
        self.assertIn('PR/base/test-merge changed', error)
        self.assertEqual(len(t.sleeps), 1)

    def test_workflow_budget_leaves_time_to_finish_proof(self):
        from test_ci_event_routing import expression_value
        job = (ROOT / '.github/workflows/ci.yml').read_text().split('\n  ci-required:\n', 1)[1]
        expression = re.search(r'^    timeout-minutes: (.+)$', job, re.M)[1][3:-3]
        minutes = expression_value(expression, {'needs.ci-plan.outputs.active': 'false'})
        self.assertGreaterEqual(minutes * 60, legacy.DEFAULT_TIMEOUT_SECONDS + 600)
        self.assertLessEqual(minutes, 360)
        for mode in ['true', '']:
            self.assertEqual(expression_value(expression, {'needs.ci-plan.outputs.active': mode}), 10)


if __name__=='__main__':unittest.main()
