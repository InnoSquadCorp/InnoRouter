"""Preview or apply the aggregate gate after its exact main dispatch succeeds."""
import argparse
import copy
import json
import subprocess
import sys

REPO = 'InnoSquadCorp/InnoRouter'
RULESET = 19074564
VARIABLE = 'INNOROUTER_CI_AGGREGATE'


def api(path, payload=None, method='GET'):
    args = ['gh', 'api', '--method', method, 'repos/' + REPO + '/' + path]
    if payload is not None:
        args += ['--input', '-']
    result = subprocess.check_output(args, input=None if payload is None else json.dumps(payload), text=True)
    return json.loads(result) if result.strip() else None


def require(value, message):
    if not value:
        raise ValueError(message)


def approved_rule(current):
    require(current.get('id') == RULESET and current.get('target') == 'branch' and
            current.get('enforcement') == 'active', 'unexpected main protection ruleset')
    payload = {key: copy.deepcopy(current[key]) for key in
               ('name', 'target', 'enforcement', 'conditions', 'rules', 'bypass_actors') if key in current}
    checks = [rule for rule in payload['rules'] if rule['type'] == 'required_status_checks']
    require(len(checks) == 1 and checks[0]['parameters']['strict_required_status_checks_policy'] is True,
            'strict required checks must already be enabled')
    checks[0]['parameters']['required_status_checks'] = [
        dict(context=name, integration_id=15368) for name in ('CI Required', 'Dependabot Merge Ready')]
    return payload


def proof(get, run_id):
    main = get('git/ref/heads/main')['object']['sha']
    run = get(f'actions/runs/{run_id}')
    require(run.get('id') == run_id and run.get('head_sha') == main and
            run.get('head_branch') == 'main' and run.get('path') == '.github/workflows/ci.yml' and
            run.get('event') == 'workflow_dispatch' and run.get('status') == 'completed' and
            run.get('conclusion') == 'success' and run.get('repository', {}).get('full_name') == REPO,
            'a successful aggregate dispatch at the current main SHA is required')
    jobs = get(f'actions/runs/{run_id}/attempts/{run["run_attempt"]}/jobs?per_page=100')
    require(jobs.get('total_count') == len(jobs.get('jobs', [])), 'incomplete dispatch job inventory')
    required = [j for j in jobs['jobs'] if j.get('name') == 'CI Required']
    require(len(required) == 1, 'missing/duplicate native aggregate gate')
    job = required[0]
    require(job.get('conclusion') == 'success' and job.get('run_id') == run_id and
            job.get('head_sha') == main, 'aggregate gate did not pass on main')
    steps = {s['name']: s.get('conclusion') for s in job.get('steps', [])}
    require(steps.get('Require exact planned dependencies') == 'success' and
            steps.get('Verify prior validation for metadata') == 'skipped' and
            steps.get('Reuse original protected checks during rollout') == 'skipped',
            'dispatch must use the new full aggregate contract, not transition evidence')
    prefix = f'https://api.github.com/repos/{REPO}/check-runs/'
    check_url = job.get('check_run_url', '')
    require(check_url.startswith(prefix) and check_url[len(prefix):].isdigit(), 'missing native check identity')
    check = get('check-runs/' + check_url[len(prefix):])
    require(check.get('app', {}).get('id') == 15368 and check.get('name') == 'CI Required' and
            check.get('head_sha') == main and check.get('conclusion') == 'success' and
            check.get('check_suite', {}).get('id') == run['check_suite_id'] and
            check.get('details_url') == f'https://github.com/{REPO}/actions/runs/{run_id}/job/{job["id"]}',
            'unverified GitHub Actions aggregate check')
    require(get(f'actions/runs/{run_id}') == run and get('git/ref/heads/main')['object']['sha'] == main,
            'main or dispatch changed during proof')
    return main


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run-id', type=int, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    try:
        sha = proof(api, args.run_id)
        current = api(f'rulesets/{RULESET}')
        payload = approved_rule(current)
        print(json.dumps(dict(main=sha, ruleset=payload, variable={VARIABLE: 'true'}), indent=2))
        if args.apply:
            require(proof(api, args.run_id) == sha and api(f'rulesets/{RULESET}') == current,
                    'protection or validation changed before rollout')
            # First require the gate that already verifies every legacy check in
            # transition mode. Only then enable selective aggregate execution.
            api(f'rulesets/{RULESET}', payload, 'PUT')
            installed = api(f'rulesets/{RULESET}')
            require(all(installed.get(key) == value for key, value in payload.items()),
                    'protection readback failed before variable activation')
            variables = api('actions/variables?per_page=100')
            require(variables['total_count'] == len(variables['variables']), 'incomplete variable inventory')
            exists = any(v['name'] == VARIABLE for v in variables['variables'])
            api('actions/variables/' + VARIABLE if exists else 'actions/variables',
                dict(name=VARIABLE, value='true'), 'PATCH' if exists else 'POST')
            actual = api(f'rulesets/{RULESET}')
            require(all(actual.get(key) == value for key, value in payload.items()) and
                    api('actions/variables/' + VARIABLE)['value'] == 'true', 'rollout readback failed')
            print('Aggregate gate and variable applied; verify the next source and docs PRs.')
        return 0
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print('CI rollout rejected: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
