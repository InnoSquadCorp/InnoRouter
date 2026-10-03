"""Recognize native metadata rechecks; never substitute them for real CI proof.

A title is a candidate, not evidence. Bind the immutable workflow definition,
merge parents, complete job/check inventory and latest attempt before excluding
one from latest-validation selection. Unknown evidence blocks the caller.
"""
import itertools
import importlib.util
from pathlib import Path
import re

_spec = importlib.util.spec_from_file_location('managed', Path(__file__).with_name('ci-managed-checks.py'))
managed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(managed)

PREFIX = 'CI metadata-only v1 '
TITLE = re.compile(PREFIX + r'pr:([1-9][0-9]*) head:([0-9a-f]{40}) base:([0-9a-f]{40}) action:(labeled|unlabeled|edited) source:([0-9a-f]{40})')
PATH = '.github/workflows/ci.yml'
DIRECT = {'Exact-SHA external macro consumer', 'CI and public operations policy', 'CI Plan', 'Documentation contracts'}
CALLS = (({'CI core'}, {'CI core / release-contract', 'CI core / changelog-sync', 'CI core / lint', 'CI core / gates'}), ({'CI docc'}, {'CI docc / docc'}), ({'CI platforms'}, {'CI platforms / Platforms Required', 'CI platforms / test Inspector UI (iPadOS)', 'CI platforms / test ${{ matrix.platform.name }}', 'CI platforms / build ${{ matrix.platform.name }}'}), ({'CI coverage'}, {'CI coverage / codecov', 'CI coverage / coverage'}), ({'CI sanitizers'}, {'CI sanitizers / ${{ matrix.kind }} sanitizer', 'CI sanitizers / Sanitizers Required'}), ({'CI performance'}, {'CI performance / smoke'}), ({'CI migration'}, {'CI migration / migration'}))
GATES = {'CI Required': 'Require exact planned dependencies'}
INVENTORIES = [DIRECT.union(GATES, *children) for children in itertools.product(*CALLS)]


def partition(api, runs, *, repository, repository_id, workflow_id, number, head, source, require):
    """Return validation runs, exempt check IDs and verified (run, attempt) pairs."""
    route = 'repos/' + repository + '/'
    validations, ignored, metadata_runs = [], set(), set()
    expected_blob = None
    require(all(type(r.get('id')) is int and r['id'] > 0 and
                type(r.get('run_number')) is int and r['run_number'] > 0 for r in runs),
            'invalid CI run ordering')
    ordinary = [r for r in runs if not str(r.get('display_title', '')).startswith(PREFIX)]
    latest_validation = max((r.get('run_number', 0) for r in ordinary), default=0)
    for listed in runs:
        # Older terminal runs already use the caller's ordinary historical
        # handling. Do not let a metadata run from an obsolete base/workflow
        # block a later real validation, or reread its entire job inventory.
        if (not str(listed.get('display_title', '')).startswith(PREFIX) or
                listed.get('run_number', 0) < latest_validation):
            validations.append(listed)
            continue
        run = api.get(route + f"actions/runs/{listed['id']}")
        binding = TITLE.fullmatch(run.get('display_title', ''))
        require(binding is not None, 'invalid metadata-only event binding')
        pr, bound_head, base, action, definition = binding.groups()
        require(int(pr) == number and bound_head == head and
                run.get('id') == listed['id'] and run.get('run_number') == listed.get('run_number') and
                run.get('workflow_id') == workflow_id and run.get('path') == PATH and
                run.get('event') == 'pull_request' and run.get('head_sha') == head and
                run.get('repository', {}).get('id') == repository_id and
                run.get('head_repository', {}).get('id') == repository_id and
                run.get('status') == 'completed' and run.get('conclusion') in {'success', 'skipped'} and
                type(run.get('run_attempt')) is int and 0 < run['run_attempt'] <= 100 and
                type(run.get('check_suite_id')) is int and run['check_suite_id'] > 0,
                'metadata run is pending, foreign or unbound')
        commit = api.get(route + 'git/commits/' + definition)
        require(commit.get('sha') == definition and
                [p.get('sha') for p in commit.get('parents', [])] == [base, head],
                'metadata workflow is not its event merge commit')
        if expected_blob is None:
            expected_blob = api.get(route + 'contents/' + PATH + '?ref=' + source).get('sha', '')
            require(re.fullmatch(r'[0-9a-f]{40}', expected_blob) is not None,
                    'missing current workflow identity')
        blob = api.get(route + 'contents/' + PATH + '?ref=' + definition).get('sha')
        require(blob == expected_blob, 'metadata workflow differs from current validation definition')
        checks = api.pages(route + f"check-suites/{run['check_suite_id']}/check-runs?filter=all", 'check_runs')
        by_id = {c.get('id'): c for c in checks}
        require(len(by_id) == len(checks), 'duplicate metadata checks')
        observed, managed_ids = set(), set()
        for attempt in range(1, run['run_attempt'] + 1):
            jobs = api.pages(route + f"actions/runs/{run['id']}/attempts/{attempt}/jobs", 'jobs')
            jobs, excluded = managed.validation_jobs(api, jobs, {**run, 'run_attempt': attempt}, repository, head, number)
            managed_ids.update(excluded)
            names = [j.get('name') for j in jobs]
            require(len(names) == len(set(names)) and set(names) in INVENTORIES,
                    'missing, extra or validation-named metadata job')
            for job in jobs:
                url = job.get('check_run_url', '')
                prefix = 'https://api.github.com/' + route + 'check-runs/'
                require(url.startswith(prefix) and re.fullmatch(r'[1-9][0-9]*', url[len(prefix):]) is not None,
                        'missing native metadata job/check association')
                check_id = int(url[len(prefix):])
                require(check_id not in observed, 'duplicate metadata job/check association')
                observed.add(check_id)
                check = by_id.get(check_id, {})
                gate = job['name'] in GATES
                expected = 'success' if gate else 'skipped'
                if gate:
                    steps = job.get('steps', [])
                    verify = [s for s in steps if s.get('name') == 'Verify prior validation for metadata']
                    normal = [s for s in steps if s.get('name') == GATES[job['name']]]
                    require(len(verify) == 1 and verify[0].get('conclusion') == 'success' and
                            len(normal) == 1 and normal[0].get('conclusion') == 'skipped' and
                            all(s.get('status') == 'completed' and s.get('conclusion') in {'success', 'skipped'}
                                for s in steps), 'metadata gate did not verify prior validation')
                else:
                    require(job.get('steps') == [], 'metadata run executed validation work')
                require(type(job.get('id')) is int and job['id'] > 0 and
                        job.get('run_id') == run['id'] and job.get('run_attempt') == attempt and
                        job.get('head_sha') == head and job.get('status') == 'completed' and
                        job.get('conclusion') == expected and
                        check.get('name') == job['name'] and check.get('app', {}).get('id') == 15368 and
                        check.get('check_suite', {}).get('id') == run['check_suite_id'] and
                        check.get('head_sha') in {head, definition} and check.get('status') == 'completed' and
                        check.get('conclusion') == expected and check.get('details_url') ==
                        f"https://github.com/{repository}/actions/runs/{run['id']}/job/{job['id']}",
                        'metadata run executed work or has unverified native checks')
        require(set(by_id) == observed | managed_ids, 'unassociated metadata checks')
        final = api.get(route + f"actions/runs/{run['id']}")
        require(all(final.get(k) == run.get(k) for k in (
            'id', 'run_number', 'run_attempt', 'workflow_id', 'path', 'event', 'display_title',
            'head_sha', 'repository', 'head_repository', 'check_suite_id', 'status', 'conclusion')),
            'metadata run changed while reading proof')
        ignored.update(observed)
        metadata_runs.add((run['id'], run['run_attempt']))
    return validations, ignored, metadata_runs
