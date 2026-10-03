"""Separate the coordinator's API-created Ready check from native CI jobs."""


def validation_jobs(api, jobs, run, repository, head, number):
    validation, managed = [], set()
    for job in jobs:
        if job.get('name') != 'Dependabot Merge Ready':
            validation.append(job)
            continue
        prefix = f'https://api.github.com/repos/{repository}/check-runs/'
        url = job.get('check_run_url', '')
        if (type(number) is not int or number <= 0 or not url.startswith(prefix) or
                not url[len(prefix):].isdigit() or job.get('steps') != [] or
                job.get('run_id') != run['id'] or job.get('run_attempt') != run['run_attempt']):
            raise ValueError('unverified managed Ready job identity')
        check_id = int(url[len(prefix):])
        check = api.get(f'repos/{repository}/check-runs/{check_id}')
        if (check.get('id') != check_id or job.get('id') != check_id or
                check.get('app', {}).get('id') != 15368 or
                check.get('name') != 'Dependabot Merge Ready' or check.get('head_sha') != head or
                check.get('external_id') != f'dependabot-policy:{number}:{head}' or
                check.get('check_suite', {}).get('id') != run['check_suite_id'] or
                check.get('details_url') != f'https://github.com/{repository}/runs/{check_id}'):
            raise ValueError('unverified managed Ready check provenance')
        managed.add(check_id)
    if len(managed) != len(jobs) - len(validation) or len(managed) > 1:
        raise ValueError('duplicate managed Ready jobs')
    # Ready is independently required and may be pending while CI runs. Its
    # conclusion must never replace, or introduce a cycle in, native CI proof.
    return validation, managed
