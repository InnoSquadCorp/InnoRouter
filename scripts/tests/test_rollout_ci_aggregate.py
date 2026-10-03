"""Rollout proof, protection preservation and safe settings write order."""
import copy
import importlib.util
import io
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('rollout', ROOT / 'scripts/rollout-ci-aggregate.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)
SHA = 'a' * 40


class Transcript:
    def __init__(self):
        self.ref = dict(object=dict(sha=SHA))
        self.run = dict(id=10, head_sha=SHA, head_branch='main', path='.github/workflows/ci.yml',
                        event='workflow_dispatch', status='completed', conclusion='success',
                        repository=dict(full_name=p.REPO), run_attempt=2, check_suite_id=20)
        self.job = dict(id=30, run_id=10, head_sha=SHA, name='CI Required', conclusion='success',
                        check_run_url=f'https://api.github.com/repos/{p.REPO}/check-runs/40',
                        steps=[dict(name=name, conclusion=result) for name, result in [
                            ('Require exact planned dependencies', 'success'),
                            ('Verify prior validation for metadata', 'skipped'),
                            ('Reuse original protected checks during rollout', 'skipped')]])
        self.jobs = dict(total_count=1, jobs=[self.job])
        self.check = dict(app=dict(id=15368), name='CI Required', head_sha=SHA, conclusion='success',
                          check_suite=dict(id=20), details_url=f'https://github.com/{p.REPO}/actions/runs/10/job/30')
        self.rule = dict(id=p.RULESET, name='Main protection', target='branch', enforcement='active',
                         conditions=dict(ref_name=dict(include=['refs/heads/main'], exclude=[])),
                         bypass_actors=[], rules=[dict(type='deletion'), dict(type='required_status_checks',
                             parameters=dict(strict_required_status_checks_policy=True,
                                             required_status_checks=[dict(context='legacy', integration_id=15368)]))])
        self.variables = []
        self.writes = []
        self.fail_variable = False
        self.ignore_rule_write = False
        self.ref_reads = 0
        self.race_main = False

    def api(self, path, payload=None, method='GET'):
        if method != 'GET':
            self.writes.append((path, copy.deepcopy(payload), method))
            if path == f'rulesets/{p.RULESET}':
                if not self.ignore_rule_write: self.rule.update(copy.deepcopy(payload))
            elif path.startswith('actions/variables'):
                if self.fail_variable: raise OSError('variable write failed')
                self.variables = [copy.deepcopy(payload)]
            else: raise AssertionError(path)
            return None
        if path == 'git/ref/heads/main':
            self.ref_reads += 1
            if self.race_main and self.ref_reads > 1: self.ref['object']['sha'] = 'b' * 40
            result = self.ref
        elif path == 'actions/runs/10': result = self.run
        elif path == 'actions/runs/10/attempts/2/jobs?per_page=100': result = self.jobs
        elif path == 'check-runs/40': result = self.check
        elif path == f'rulesets/{p.RULESET}': result = self.rule
        elif path == 'actions/variables?per_page=100': result = dict(total_count=len(self.variables), variables=self.variables)
        elif path == 'actions/variables/' + p.VARIABLE: result = self.variables[0]
        else: raise AssertionError(path)
        return copy.deepcopy(result)

    def execute(self, apply=False):
        argv = ['rollout', '--run-id', '10'] + (['--apply'] if apply else [])
        with mock.patch.object(p, 'api', side_effect=self.api), mock.patch('sys.argv', argv), \
                mock.patch('sys.stdout', new_callable=io.StringIO), mock.patch('sys.stderr', new_callable=io.StringIO):
            return p.main()


class RolloutTests(unittest.TestCase):
    def test_preview_is_read_only_and_preserves_unrelated_protection(self):
        t = Transcript()
        self.assertEqual(t.execute(), 0)
        self.assertEqual(t.writes, [])
        before = copy.deepcopy(t.rule)
        payload = p.approved_rule(t.rule)
        self.assertEqual(t.rule, before)
        self.assertEqual(payload['rules'][0], before['rules'][0])
        self.assertEqual(payload['conditions'], before['conditions'])
        self.assertEqual(payload['bypass_actors'], [])
        self.assertEqual(payload['rules'][1]['parameters'], dict(strict_required_status_checks_policy=True,
            required_status_checks=[dict(context=name, integration_id=15368)
                                    for name in ['CI Required', 'Dependabot Merge Ready']]))

    def test_full_native_current_main_dispatch_is_required_before_any_write(self):
        changes = [lambda t: t.run.update(head_sha='b' * 40), lambda t: t.run.update(event='push'),
                   lambda t: t.run.update(conclusion='failure'), lambda t: t.run.update(head_branch='feature'),
                   lambda t: t.check['app'].update(id=1), lambda t: t.check['check_suite'].update(id=99),
                   lambda t: t.check.update(details_url='https://example.invalid'),
                   lambda t: t.job['steps'][2].update(conclusion='success'),
                   lambda t: t.job['steps'][0].update(conclusion='skipped'),
                   lambda t: t.jobs.update(total_count=2), lambda t: setattr(t, 'race_main', True),
                   lambda t: t.rule.update(enforcement='disabled')]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                t = Transcript(); change(t)
                self.assertEqual(t.execute(True), 1)
                self.assertEqual(t.writes, [])

    def test_protection_precedes_variable_activation_for_new_and_existing_variable(self):
        for exists in [False, True]:
            with self.subTest(exists=exists):
                t = Transcript()
                if exists: t.variables = [dict(name=p.VARIABLE, value='false')]
                self.assertEqual(t.execute(True), 0)
                self.assertEqual([method for _, _, method in t.writes], ['PUT', 'PATCH' if exists else 'POST'])
                self.assertEqual(t.writes[0][0], f'rulesets/{p.RULESET}')
                self.assertEqual(t.variables[0]['value'], 'true')

    def test_variable_failure_keeps_the_verified_gate_required(self):
        t = Transcript(); t.fail_variable = True
        self.assertEqual(t.execute(True), 1)
        self.assertEqual(t.rule['rules'][1]['parameters']['required_status_checks'][0]['context'], 'CI Required')
        self.assertEqual(t.variables, [])

    def test_readback_detects_unapplied_protection(self):
        t = Transcript(); t.ignore_rule_write = True
        self.assertEqual(t.execute(True), 1)
        self.assertEqual(t.variables, [])
        self.assertEqual(len(t.writes), 1)


if __name__ == '__main__':
    unittest.main()
