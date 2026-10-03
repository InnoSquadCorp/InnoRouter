"""GitHub can expose API-created Ready checks in a workflow's jobs response."""
import copy
import unittest

import test_dependabot_merge as bot
from test_ci_metadata_policy import MetadataAPI, yaml, ROOT
from test_legacy_ci import QueueTranscript, legacy
from test_verify_ci_metadata import Transcript


def ready(run, number, head, conclusion=None):
    check_id = 8000008
    job = dict(id=check_id, name='Dependabot Merge Ready', run_id=run['id'],
               run_attempt=run['run_attempt'], head_sha=head, status='in_progress' if conclusion is None else 'completed',
               conclusion=conclusion, steps=[],
               check_run_url=f'https://api.github.com/repos/{bot.REPO}/check-runs/{check_id}')
    check = dict(id=check_id, name=job['name'], head_sha=head, app=dict(id=15368),
                 external_id=f'dependabot-policy:{number}:{head}', check_suite=dict(id=run['check_suite_id']),
                 status=job['status'], conclusion=conclusion,
                 details_url=f'https://github.com/{bot.REPO}/runs/{check_id}')
    return job, check


class ManagedCheckTests(unittest.TestCase):
    def test_legacy_proof_ignores_only_attributed_managed_ready(self):
        for conclusion in [None, 'success', 'failure']:
            t = QueueTranscript(0)
            job, check = ready(t.runs[0], 55, bot.HEAD, conclusion)
            t.jobs[1].append(job); t.checks[check['id']] = check
            self.assertEqual(t.execute(), (0, ''))

    def test_names_alone_cannot_bypass_inventory_validation(self):
        changes = [lambda j, c: c['app'].update(id=1), lambda j, c: c.update(head_sha='f' * 40),
                   lambda j, c: c.update(external_id=f'dependabot-policy:56:{bot.HEAD}'),
                   lambda j, c: c['check_suite'].update(id=999), lambda j, c: c.update(id=9),
                   lambda j, c: c.update(details_url='https://example.invalid'),
                   lambda j, c: j.update(id=9), lambda j, c: j.update(run_attempt=2),
                   lambda j, c: j.update(run_id=999), lambda j, c: j.update(steps=[dict(name='executed')]),
                   lambda j, c: j.update(check_run_url='https://example.invalid/8')]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                t = QueueTranscript(0)
                job, check = ready(t.runs[0], 55, bot.HEAD)
                t.jobs[1].append(job); t.checks[check['id']] = check
                change(job, check)
                result, error = t.execute()
                self.assertEqual(result, 1)
                self.assertIn('unverified managed Ready', error)

    def test_managed_ready_cannot_replace_failed_missing_or_duplicate_native_job(self):
        for change in [lambda t: t.jobs[1].pop(0),
                       lambda t: t.jobs[1][0].update(conclusion='failure'),
                       lambda t: t.jobs[1].append(copy.deepcopy(t.jobs[1][-1]))]:
            t = QueueTranscript(0)
            job, check = ready(t.runs[0], 55, bot.HEAD, 'success')
            t.jobs[1].append(job); t.checks[check['id']] = check
            change(t)
            self.assertEqual(t.execute()[0], 1)

    def test_coordinator_handles_managed_check_in_either_workflow(self):
        for active, run_id in [(False, 100), (False, 101), (True, 100)]:
            api = bot.API(active)
            job, check = ready(api.runs[run_id], 55, bot.HEAD)
            api.jobs[run_id].append(job); api.checks.append(check)
            self.assertEqual(bot.policy.proof(api, 55)['run'], 100)

    def test_metadata_revalidation_does_not_depend_on_pending_ready(self):
        api = Transcript()
        job, check = ready(api.run, 45, bot.HEAD)
        api.jobs.append(job); api.checks[check['id']] = check
        self.assertEqual(api.prove()['run'], 10)

    def test_metadata_partition_keeps_managed_ready_out_of_native_inventory(self):
        api = MetadataAPI()
        job, check = ready(api.run, 55, bot.HEAD)
        api.jobs.append(job); api.checks.append(check)
        self.assertEqual(bot.policy.proof(api, 55)['run'], 100)

    def test_coordinator_contract_tracks_actual_required_step_and_metadata_skip(self):
        steps = yaml(ROOT / '.github/workflows/ci.yml')['jobs']['ci-required']['steps']
        self.assertIn(bot.adapter.PRIMARY['CI Required'], [s.get('name') for s in steps])
        self.assertTrue(bot.adapter.skip_step('CI Required', 'Verify prior validation for metadata', False))
        self.assertFalse(bot.adapter.skip_step('CI Required', bot.adapter.PRIMARY['CI Required'], False))


if __name__ == '__main__':
    unittest.main()
