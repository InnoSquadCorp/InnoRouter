#!/usr/bin/env python3
"""Read-only transition bridge: reuse the original checks plus the forward-toolchain lane without duplicate builds."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

_spec = importlib.util.spec_from_file_location('managed', Path(__file__).with_name('ci-managed-checks.py'))
managed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(managed)

# Separate workflows can spend hours queued for macOS runners. Keep the bridge
# bounded below GitHub's six-hour job limit, with time left for final proof.
DEFAULT_TIMEOUT_SECONDS = 330 * 60
MAX_POLL_SECONDS = 120

LEGACY = {
    '.github/workflows/principle-gates.yml': ('lint', 'changelog-sync', 'release-contract', 'gates', 'forward toolchain (Xcode 27)'),
    '.github/workflows/docs-ci.yml': ('docc',),
    '.github/workflows/coverage.yml': ('coverage', 'codecov'),
    '.github/workflows/migration-smoke.yml': ('migration',),
    '.github/workflows/performance-smoke.yml': ('smoke',),
    '.github/workflows/sanitizers.yml': ('thread sanitizer', 'address sanitizer', 'Sanitizers Required'),
    '.github/workflows/platforms.yml': ('test Inspector UI (iPadOS)', 'Platforms Required') + tuple(
        'build ' + x for x in ('iOS', 'iPadOS', 'Mac-Catalyst', 'macOS', 'tvOS', 'watchOS', 'visionOS')) + tuple(
        'test ' + x for x in ('iOS', 'iPadOS', 'Mac-Catalyst', 'tvOS', 'watchOS', 'visionOS')),
}


class Pending(ValueError):
    pass


def latest_runs(runs, event, sha, number=None):
    selected = {}
    pending = []
    for path in LEGACY:
        matches = [r for r in runs if r.get('path', '').split('@')[0] == path and r.get('event') == event
                   and r.get('head_sha') == sha and (number is None or any(
                       p.get('number') == number for p in r.get('pull_requests', [])))]
        if not matches:
            pending.append('missing run: ' + path)
            continue
        # Latest created run, then latest attempt of that run. Earlier green runs
        # never mask a pending rerun or a later failed run.
        run = max(matches, key=lambda r: (r['created_at'], r['id'], r['run_attempt']))
        if run.get('status') != 'completed':
            pending.append('incomplete run: ' + path)
            continue
        if run.get('conclusion') != 'success':
            raise ValueError('failed/cancelled/skipped latest run: ' + path)
        selected[path] = run
    # A queued workflow must not mask a terminal failure later in the inventory.
    if pending:
        raise Pending('; '.join(pending))
    return selected


def validate_jobs(path, run, jobs):
    if len(jobs) != len(LEGACY[path]) or {j.get('name') for j in jobs} != set(LEGACY[path]):
        raise ValueError('missing, duplicate or unexpected legacy job: ' + path)
    for job in jobs:
        if job.get('run_id') != run['id'] or job.get('run_attempt') != run['run_attempt']:
            raise ValueError('stale job attempt: ' + path)
        expected = 'skipped' if job['name'] == 'codecov' and (run.get('event') != 'push' or run.get('head_branch') != 'main') else 'success'
        if job.get('status') != 'completed' or job.get('conclusion') != expected:
            raise ValueError('legacy child did not succeed: ' + job['name'])


def validate_check(job, run, check, head, merge=None):
    repository = 'InnoSquadCorp/InnoRouter'
    if (check.get('app', {}).get('id') != 15368 or check.get('name') != job['name']
            or check.get('check_suite', {}).get('id') != run['check_suite_id']
            or check.get('head_sha') not in {head, merge or head}
            or check.get('status') != 'completed' or check.get('conclusion') != job['conclusion']
            or check.get('details_url') != f"https://github.com/{repository}/actions/runs/{run['id']}/job/{job['id']}"):
        raise ValueError('wrong app/suite/head/job check attribution')


class API:
    def __init__(self, repo, token):
        if repo != 'InnoSquadCorp/InnoRouter':
            raise ValueError('unexpected repository')
        self.repo = repo
        self.token = token

    def get(self, path):
        req = urllib.request.Request('https://api.github.com/' + path, headers={
            'Authorization': 'Bearer ' + self.token, 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28'})
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)

    def pages(self, path, key):
        results = []
        for page in range(1, 101):
            payload = self.get(path + ('&' if '?' in path else '?') + f'per_page=100&page={page}')
            values = payload[key] if key else payload
            if not isinstance(values, list):
                raise ValueError('invalid paginated response')
            results.extend(values)
            if len(values) < 100:
                return results
        raise ValueError('pagination limit reached')


def current_pr(api, number, head, base, merge):
    pr = api.get(f'repos/{api.repo}/pulls/{number}')
    if (pr['state'] != 'open' or pr['head']['sha'] != head or pr['base']['sha'] != base
            or pr.get('merge_commit_sha') != merge or pr['base']['ref'] != 'main'):
        raise ValueError('PR/base/test-merge changed; a fresh CI run is required')
    return pr


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--event', required=True)
    p.add_argument('--sha', required=True)
    p.add_argument('--number', type=int)
    p.add_argument('--base')
    p.add_argument('--merge')
    p.add_argument('--timeout', type=int, default=DEFAULT_TIMEOUT_SECONDS)
    args = p.parse_args()
    try:
        api = API(os.environ['GITHUB_REPOSITORY'], os.environ['GH_TOKEN'])
        start = time.monotonic()
        poll_seconds = 15
        while True:
            if args.number:
                current_pr(api, args.number, args.sha, args.base, args.merge)
            runs = api.pages(f'repos/{api.repo}/actions/runs?head_sha={args.sha}&event={args.event}', 'workflow_runs')
            try:
                selected = latest_runs(runs, args.event, args.sha, args.number)
                for path, run in selected.items():
                    if args.number and not any(p.get('number') == args.number and p.get('base', {}).get('sha') == args.base
                                               and p.get('head', {}).get('sha') == args.sha for p in run.get('pull_requests', [])):
                        raise ValueError('legacy run tested a stale base/head')
                    jobs = api.pages(f'repos/{api.repo}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs', 'jobs')
                    jobs, _ = managed.validation_jobs(api, jobs, run, api.repo, args.sha, args.number)
                    validate_jobs(path, run, jobs)
                    for job in jobs:
                        prefix = f'https://api.github.com/repos/{api.repo}/check-runs/'
                        url = job.get('check_run_url', '')
                        if not url.startswith(prefix) or not url[len(prefix):].isdigit():
                            raise ValueError('missing/foreign job check association')
                        check = api.get(f'repos/{api.repo}/check-runs/' + url[len(prefix):])
                        validate_check(job, run, check, args.sha, args.merge)
                # Re-read latest attempts and current identities before accepting.
                latest = latest_runs(api.pages(f'repos/{api.repo}/actions/runs?head_sha={args.sha}&event={args.event}',
                                               'workflow_runs'), args.event, args.sha, args.number)
                if any((r['id'], r['run_attempt']) != (latest[path]['id'], latest[path]['run_attempt'])
                       for path, r in selected.items()):
                    raise Pending('new run/attempt arrived')
                if args.number:
                    current_pr(api, args.number, args.sha, args.base, args.merge)
                print('Transition CI Required: all original and forward-toolchain jobs succeeded at the exact current revision.')
                return 0
            except Pending as error:
                remaining = args.timeout - (time.monotonic() - start)
                if remaining <= 0:
                    raise ValueError('timed out waiting for legacy CI: ' + str(error))
                print(str(error), flush=True)
                time.sleep(min(poll_seconds, remaining))
                poll_seconds = min(poll_seconds * 2, MAX_POLL_SECONDS)
    except (ValueError, KeyError, OSError) as error:
        print('Legacy CI rejected: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
