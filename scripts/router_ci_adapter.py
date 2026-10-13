"""Frozen Router validation inventory for the trusted API-only coordinator."""
import re
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location('managed', Path(__file__).with_name('ci-managed-checks.py'))
managed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(managed)

PRIMARY = {
    'CI Plan': 'Plan exact changed paths',
    'CI and public operations policy': ('Run fail-closed policy and negative contracts',
        'Check public operations and workflow contracts', 'Verify native workflows with pinned actionlint'),
    'Documentation contracts': 'Validate copyable documentation',
    'Exact-SHA external macro consumer': 'Resolve exact event revision in a clean consumer',
    'CI Required': 'Require exact planned dependencies',
}
LEGACY = {
    'principle-gates.yml': ('CI core', {
        'lint': 'Run source-level lint gates', 'changelog-sync': 'Verify CHANGELOG matches public-API baseline change',
        'release-contract': 'Test release note rendering', 'gates': 'Run Principle Gates',
        'forward toolchain (Xcode 27)': (
            'Show toolchain', 'Test with the committed resolution',
            'Resolve the newest admitted swift-syntax', 'Test macros with the newest admitted swift-syntax',
            'Build the macro-first consumer with library evolution', 'Test the supported SwiftSyntax floor')}),
    'docs-ci.yml': ('CI docc', {'docc': 'Build DocC Site'}),
    'coverage.yml': ('CI coverage', {'coverage': 'Validate coverage floor', 'codecov': None}),
    'migration-smoke.yml': ('CI migration', {'migration': 'Compare 5.2.1 and 6.0 consumers'}),
    'performance-smoke.yml': ('CI performance', {'smoke': 'Run Canonical Runtime Performance Smoke'}),
    'sanitizers.yml': ('CI sanitizers', {
        'thread sanitizer': 'Run thread sanitizer smoke', 'address sanitizer': 'Run address sanitizer smoke',
        'Sanitizers Required': 'Require every matrix'}),
    'platforms.yml': ('CI platforms', {
        'test Inspector UI (iPadOS)': 'Verify Inspector interactions', 'Platforms Required': 'Require every matrix',
        **{'build '+p: 'Validate public interfaces for '+p for p in ('iOS','iPadOS','Mac-Catalyst','macOS','tvOS','watchOS','visionOS')},
        **{'test '+p: 'Test platform consumer for '+p for p in ('iOS','iPadOS','Mac-Catalyst','tvOS','watchOS','visionOS')}}),
}


def skip_step(job, step, active, run=None, number=None):
    # Conditional diagnostic steps are never substitutes for successful tests.
    # current_run() has already authenticated workflow/repository/head/base.
    # Mirror this one PR-scoped experiment's condition, not its display name
    # alone. It must run on PR 54's visionOS lane; ordinary platform tests remain
    # mandatory regardless of whether this diagnostic is active.
    if step == 'Compare original and explicit visionOS tab mounting':
        run=run or {}
        path=run.get('path','').split('@')[0]
        if path == '.github/workflows/platforms.yml':
            child=job
        elif active and path == '.github/workflows/ci.yml' and job.startswith('CI platforms / '):
            child=job.removeprefix('CI platforms / ')
        else:
            return False
        links=run.get('pull_requests',[])
        return (type(number) is int and number > 0 and run.get('event')=='pull_request'
                and len(links)==1 and links[0].get('number')==number
                and child in {'test '+p for p in ('iOS','iPadOS','Mac-Catalyst','tvOS','watchOS','visionOS')}
                and (number != 54 or child != 'test visionOS'))
    child = job.split(' / ')[-1]
    if child in ('thread sanitizer', 'address sanitizer') and step in (
            'Replay failed address tests under LLDB', 'Collect router crash reports'):
        return True
    if child == 'test Mac-Catalyst' and step in ('Select Mac-Catalyst simulator','Boot Mac-Catalyst simulator'):
        return True
    if child.startswith('test ') and child not in ('test iPadOS','test visionOS','test Inspector UI (iPadOS)') and step in (
            'Verify native scene closure for '+child.removeprefix('test '), 'Preserve native scene evidence'):
        return True
    return (job == 'CI Required' and (step == 'Verify prior validation for metadata' or
            (active and step == 'Reuse original protected checks during rollout'))) or (job == 'CI Plan' and step == 'Verify actual bot merge before recovery')


def validate_jobs(jobs, expected, run, head, merge, checks, repository, require, active=False, all_skipped=False, number=None):
    require(len(jobs)==len(expected) and {j.get('name') for j in jobs}==set(expected),
            'missing, duplicate or unexpected Router CI job')
    ids=set()
    for job in jobs:
        name=job['name']
        step=expected[name]
        conclusion='skipped' if all_skipped or step is None else 'success'
        require(job.get('run_id')==run['id'] and job.get('run_attempt')==run['run_attempt'], 'wrong job run/attempt')
        require(job.get('status')=='completed' and job.get('conclusion')==conclusion,
                'failed, cancelled or unexpected skipped job: '+name)
        url=job.get('check_run_url','')
        prefix=f'https://api.github.com/repos/{repository}/check-runs/'
        require(url.startswith(prefix) and url[len(prefix):].isdigit(), 'foreign/missing check association')
        check_id=int(url[len(prefix):]); ids.add(check_id)
        check=checks.get(check_id,{})
        require(check.get('app',{}).get('id')==15368 and check.get('name')==name
                and check.get('check_suite',{}).get('id')==run['check_suite_id']
                and check.get('head_sha') in {head,merge}
                and check.get('details_url')==f'https://github.com/{repository}/actions/runs/{run["id"]}/job/{job["id"]}'
                and check.get('status')=='completed' and check.get('conclusion')==conclusion,
                'wrong Actions app/suite/head/job proof: '+name)
        if conclusion=='success':
            steps=job.get('steps',[])
            required_steps=(step,) if isinstance(step,str) else step
            require(set(required_steps) <= {s.get('name') for s in steps}, 'missing core validation step: '+name)
            require(all(s.get('status')=='completed' and (s.get('conclusion')=='success' or
                        (s.get('conclusion')=='skipped' and skip_step(name,s.get('name'),active,run,number))) for s in steps),
                    'unexpected skipped/failed/incomplete step: '+name)
    return ids


def validation_runs(api, runs, workflow_id, repository_id, number, head, source, require):
    spec = importlib.util.spec_from_file_location('metadata_policy', Path(__file__).with_name('ci-metadata-policy.py'))
    metadata = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metadata)
    return metadata.partition(api, runs, repository='InnoSquadCorp/InnoRouter',
                              repository_id=repository_id, workflow_id=workflow_id,
                              number=number, head=head, source=source, require=require)


def coordinator_transport(api, check, job, run, repository, repo, pr, require):
    """Exclude only API-bound trusted coordinator transport, never CI by name."""
    path='.github/workflows/dependabot-auto-merge.yml'
    if run.get('path','').split('@')[0] != path:
        return False
    route=lambda suffix:f'repos/{repository}/{suffix}'
    workflow=api.get(route('actions/workflows/dependabot-auto-merge.yml'))
    head,number=pr['head']['sha'],pr['number']
    links=run.get('pull_requests',[])
    require(type(workflow.get('id')) is int and workflow['id']>0 and
            type(run.get('id')) is int and run['id']>0 and
            type(run.get('check_suite_id')) is int and run['check_suite_id']>0 and
            workflow.get('path')==path and workflow.get('state')=='active' and
            run.get('workflow_id')==workflow.get('id') and run.get('event')=='pull_request_target' and
            run.get('head_sha')==head and run.get('repository',{}).get('id')==repo['id'] and
            run.get('head_repository',{}).get('id')==repo['id'] and len(links)==1 and
            links[0].get('number')==number and links[0].get('head',{}).get('sha')==head and
            links[0].get('base',{}).get('ref')=='main', 'unverified coordinator run provenance')
    require(type(check.get('id')) is int and check['id']>0 and
            type(job.get('id')) is int and job['id']>0 and type(job.get('run_attempt')) is int and
            type(run.get('run_attempt')) is int and 1<=job['run_attempt']<=run['run_attempt'] and
            job.get('run_id')==run.get('id') and job.get('head_sha')==head and
            job.get('check_run_url')==f'https://api.github.com/repos/{repository}/check-runs/{check["id"]}' and
            check.get('app',{}).get('id')==15368 and check.get('head_sha')==head and
            check.get('check_suite',{}).get('id')==run.get('check_suite_id') and
            check.get('name')==job.get('name') and check.get('status')==job.get('status') and
            check.get('conclusion')==job.get('conclusion') and
            check.get('details_url')==f'https://github.com/{repository}/actions/runs/{run["id"]}/job/{job["id"]}',
            'unverified coordinator job/check association')
    name=job.get('name')
    if name in {'bot-ready','manual-ready'}:
        require(job.get('status')=='completed' and job.get('conclusion')=='skipped' and job.get('steps')==[],
                'unexpanded coordinator matrix must be an empty terminal skip')
    else:
        require(name in {'inspect',f'bot-ready ({number})',f'manual-ready ({number})','post-merge'},
                'unexpected coordinator transport job')
    return True


def verify(api, repository, pr, repo, notification, require):
    route=lambda suffix: f'repos/{repository}/{suffix}'
    head,main,merge,number=pr['head']['sha'],pr['base']['sha'],pr['merge_commit_sha'],pr['number']
    compare=api.get(route(f'compare/{main}...{head}'))
    require(compare.get('behind_by')==0 and compare.get('status') in {'ahead','identical'}, 'branch is behind latest main')
    latest={}
    metadata_check_ids=set()
    def current_run(filename, mandatory=True):
        workflow=api.get(route('actions/workflows/'+filename))
        require(workflow.get('path')=='.github/workflows/'+filename and workflow.get('state')=='active', 'wrong source workflow')
        runs=api.pages(route(f'actions/workflows/{filename}/runs?event=pull_request&head_sha={head}'),'workflow_runs')
        if filename == 'ci.yml':
            runs, ignored, _ = validation_runs(api, runs, workflow['id'], repo['id'], number, head, merge, require)
            metadata_check_ids.update(ignored)
        if not runs and not mandatory: return None
        require(bool(runs),'missing workflow: '+filename)
        candidate=max(runs,key=lambda r:(r['run_number'],r['id']))
        run=api.get(route(f'actions/runs/{candidate["id"]}'))
        require(run.get('workflow_id')==workflow['id'] and run.get('path','').split('@')[0]==workflow['path'], 'wrong run workflow identity')
        require(run.get('event')=='pull_request' and run.get('head_sha')==head
                and run.get('repository',{}).get('id')==repo['id'] and run.get('head_repository',{}).get('id')==repo['id'], 'wrong run origin/head')
        links=run.get('pull_requests',[])
        require(len(links)==1 and links[0].get('number')==number and links[0].get('head',{}).get('sha')==head
                and links[0].get('base',{}).get('sha')==main, 'stale/ambiguous PR/base/head run connection')
        require(run.get('status')=='completed' and run.get('conclusion') in {'success','skipped'}, 'latest workflow incomplete/failed')
        latest[filename]=run
        return run
    run=current_run('ci.yml')
    require(run['conclusion']=='success','CI Required workflow failed')
    if notification:
        require(notification.get('id')==run['id'] and notification.get('run_attempt')==run['run_attempt'], 'obsolete CI notification')
    jobs=api.pages(route(f'actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs'),'jobs')
    jobs, _ = managed.validation_jobs(api, jobs, run, repository, head, number)
    active='CI core / lint' in {j.get('name') for j in jobs}
    expected=dict(PRIMARY)
    if active:
        for filename,(caller,children) in LEGACY.items():
            expected.update({caller+' / '+child:step for child,step in children.items()})
    else:
        expected.update({caller:None for caller,_ in LEGACY.values()})
    checks=[]
    for sha in dict.fromkeys((head,merge)):
        checks.extend(api.pages(route(f'commits/{sha}/check-runs?filter=all'),'check_runs'))
        states={}
        for status in api.pages(route(f'commits/{sha}/statuses')):
            states.setdefault(status['context'],status)
        require(all(s.get('state')=='success' for s in states.values()),'additional commit status pending/failed')
    by_id={c['id']:c for c in checks}
    require(len(by_id)==len(checks),'duplicate check IDs')
    known=metadata_check_ids | validate_jobs(jobs,expected,run,head,merge,by_id,repository,require,active,number=number)
    # During rollout all 24 original checks are required independently of the
    # PR-controlled transition evaluator. Active CI verifies the same children.
    for filename,(caller,children) in LEGACY.items():
        legacy=current_run(filename,mandatory=not active)
        if legacy is None:continue
        legacy_jobs=api.pages(route(f'actions/runs/{legacy["id"]}/attempts/{legacy["run_attempt"]}/jobs'),'jobs')
        legacy_jobs, _ = managed.validation_jobs(api, legacy_jobs, legacy, repository, head, number)
        if active and legacy_jobs and all(j.get('conclusion')=='skipped' for j in legacy_jobs):
            require(all(j.get('status')=='completed' for j in legacy_jobs),'pending standalone skip')
            # Matrix job-level conditions can skip before matrix expansion.
            # No source execution or success is allowed in this inactive run.
            inactive={j['name']:None for j in legacy_jobs}
            known |= validate_jobs(legacy_jobs,inactive,legacy,head,merge,by_id,repository,require,active,True,number=number)
        else:
            require(legacy['conclusion']=='success','legacy gate not successful')
            known |= validate_jobs(legacy_jobs,children,legacy,head,merge,by_id,repository,require,active,number=number)
    extras={}
    protected_names=set(PRIMARY)|{n for _,children in LEGACY.values() for n in children}|set(expected)
    for check in sorted(checks,key=lambda c:c['id'],reverse=True):
        if check['id'] in known:continue
        if check.get('name')=='Dependabot Merge Ready':
            require(check.get('app',{}).get('id')==15368 and check.get('head_sha')==head
                    and check.get('external_id')==f'dependabot-policy:{number}:{head}', 'foreign Ready check identity')
            continue
        # Attribute prior attempts/runs to their original API workflow before
        # ignoring historical results; do not trust a display name alone.
        match=re.fullmatch(r'https://github.com/'+re.escape(repository)+r'/actions/runs/(\d+)/job/(\d+)',check.get('details_url',''))
        if match and check.get('app',{}).get('id')==15368:
            old_job=api.get(route('actions/jobs/'+match[2]))
            old_run=api.get(route('actions/runs/'+match[1]))
            if coordinator_transport(api,check,old_job,old_run,repository,repo,pr,require):
                continue
            path=old_run.get('path','').split('@')[0].removeprefix('.github/workflows/')
            current=latest.get(path)
            if current and old_run.get('workflow_id')==current['workflow_id'] and old_run.get('head_sha')==head and old_run.get('event')=='pull_request':
                require(old_job.get('run_id')==old_run['id'] and old_job.get('name')==check.get('name'), 'wrong historical job association')
                require(old_run['id']<current['id'] or (old_run['id']==current['id'] and old_job.get('run_attempt',0)<current['run_attempt']),
                        'unexpected duplicate/current/future attempt check')
                continue
        require(check.get('name') not in protected_names,'foreign workflow/app spoofed required context')
        extras.setdefault((check.get('head_sha'),check.get('name'),check.get('app',{}).get('id')),check)
    require(all(c.get('status')=='completed' and c.get('conclusion')=='success' for c in extras.values()), 'additional check failed/pending/unexpected skip')
    return {'run':run['id'],'attempt':run['run_attempt'],
            'evidence':tuple(sorted((name,r['id'],r['run_attempt']) for name,r in latest.items()))}
