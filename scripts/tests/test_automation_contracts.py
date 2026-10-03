import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]

def load(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py')
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def candidate_fixture(directory, version):
    """A synthetic release cut independent of development HEAD/Unreleased."""
    fixture=Path(directory);fixture.mkdir(parents=True,exist_ok=True)
    shutil.copytree(ROOT/'scripts',fixture/'scripts',ignore=shutil.ignore_patterns('__pycache__'))
    runtime=fixture/'Sources/InnoRouterCore/InnoRouterVersion.swift';runtime.parent.mkdir(parents=True)
    runtime.write_text('public enum InnoRouterVersion {\n    public static let current = "'+version+'"\n}\n')
    for name in ('README.md','README.ko.md'):
        (fixture/name).write_text('.package(url: "https://github.com/InnoSquadCorp/InnoRouter.git", from: "'+version+'")\n')
    notes='# Changelog\n\n## Unreleased\n\n'
    notes+=('- Candidate note.\n' if '-' in version else '## '+version+' - 2026-09-30\n\n- Released note.\n')
    (fixture/'CHANGELOG.md').write_text(notes)
    env={**os.environ,'GIT_AUTHOR_NAME':'Fixture','GIT_COMMITTER_NAME':'Fixture',
         'GIT_AUTHOR_EMAIL':'fixture@example.invalid','GIT_COMMITTER_EMAIL':'fixture@example.invalid'}
    def git(*args):
        return subprocess.check_output(['git','-C',str(fixture),'-c','commit.gpgsign=false',*args],env=env,text=True).strip()
    git('init','-q','-b','main');git('add','.');git('commit','-qm','synthetic release baseline')
    sha=git('rev-parse','HEAD');git('update-ref','refs/remotes/origin/main',sha)
    return fixture,sha,git,env


class AutomationContracts(unittest.TestCase):
    def test_dependabot_cannot_become_partial_when_labels_are_missing(self):
        policy=load('ci-policy')
        for path in ('README.md','.github/dependabot.yml','Package.resolved'):
            event={'action':'opened','pull_request':{'labels':[], 'user':{'login':'dependabot[bot]'}}}
            self.assertTrue(all(policy.make_plan('pull_request',event,[path])['jobs'].values()))

    def test_public_operations_and_historical_exclusion(self):
        guard=load('check-public-operations')
        guard.check()
        config=json.loads((ROOT/'.github/dependabot.yml').read_text())
        swift=next(u for u in config['updates'] if u['package-ecosystem']=='swift')
        self.assertNotIn('/MigrationSmoke/Before',swift['directories'])
        self.assertNotIn('/MigrationSmoke/After',swift['directories'])
        self.assertNotIn('prefix-development',swift['commit-message'])

    def test_official_swift_fetcher_inventory_includes_xcode_lock(self):
        guard=load('check-public-operations')
        nested=guard.LIVE_LOCKS[-1]
        # Old scope selects Package.swift and returns before Xcode discovery.
        self.assertNotIn(nested,guard.swift_fetch_inventory(ROOT,'/NativeSceneSmoke'))
        self.assertIn(nested,guard.swift_fetch_inventory(ROOT,'/NativeSceneSmoke/NativeSceneSmoke.xcodeproj'))
        with tempfile.TemporaryDirectory() as temp:
            fixture=Path(temp);shutil.copytree(ROOT/'NativeSceneSmoke',fixture/'NativeSceneSmoke',
                ignore=shutil.ignore_patterns('.build','build'))
            selected=fixture/'NativeSceneSmoke/NativeSceneSmoke.xcodeproj'
            (selected/'Package.swift').write_text('// A manifest silently changes official fetch mode.\n')
            self.assertNotIn(nested,guard.swift_fetch_inventory(fixture,'/NativeSceneSmoke/NativeSceneSmoke.xcodeproj'))

    def test_unsupported_or_partial_dependency_updates_fail_closed(self):
        import shutil
        guard=load('check-public-operations')
        with tempfile.TemporaryDirectory(prefix='router-public-ops-') as temp:
            fixture=Path(temp)
            for name in ('.github/dependabot.yml','.spi.yml','Package.swift','Package.resolved',
                         'ConsumerSmoke/Package.swift','ConsumerSmoke/Package.resolved','NativeSceneSmoke/Package.swift',
                         'NativeSceneSmoke/NativeSceneSmoke.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
                         'LICENSE','SECURITY.md','CONTRIBUTING.md','RELEASING.md','Docs/automation-policy.md',
                         '.github/PULL_REQUEST_TEMPLATE.md','.github/ISSUE_TEMPLATE/bug_report.yml','.github/ISSUE_TEMPLATE/feature_request.yml'):
                target=fixture/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,target)
            guard.check(fixture)
            original=json.loads((fixture/'.github/dependabot.yml').read_text())
            for mutate in (
                    lambda x: x['updates'][1]['directories'].append('/MigrationSmoke/Before'),
                    lambda x: x['updates'][1]['commit-message'].update({'prefix-development':'chore(dev)'}),
                    lambda x: x['updates'][1]['groups']['swift-minor-patch'].update({'dependency-type':'production'}),
                    lambda x: x['updates'][1]['groups']['swift-minor-patch'].update({'exclude-patterns':['swift-syntax']}),
                    lambda x: x['updates'][0]['schedule'].update({'timezone':'UTC'}),
                    lambda x: x['updates'][1].update({'open-pull-requests-limit':5})):
                altered=json.loads(json.dumps(original));mutate(altered)
                (fixture/'.github/dependabot.yml').write_text(json.dumps(altered))
                with self.assertRaises(ValueError):guard.check(fixture)
            (fixture/'.github/dependabot.yml').write_text(json.dumps(original))
            path=fixture/'ConsumerSmoke/Package.resolved';lock=json.loads(path.read_text())
            state=next(pin['state'] for pin in lock['pins'] if pin['identity']=='swift-syntax')
            state['version']=str(int(state['version'].split('.')[0])+1)+'.0.0'
            path.write_text(json.dumps(lock))
            with self.assertRaises(ValueError):guard.check(fixture)

    def test_reviewed_swift_syntax_range_and_complete_locks(self):
        guard=load('check-public-operations')
        with tempfile.TemporaryDirectory() as temp:
            fixture=Path(temp)
            shutil.copytree(ROOT,fixture,dirs_exist_ok=True,ignore=shutil.ignore_patterns('.git','.build','__pycache__'))
            original=(fixture/'Package.swift').read_text()
            guard.check(fixture)
            for lo,hi in (('603.0.2','606.0.0'),('604.0.0','605.0.0'),('603.0.0','605.0.0')):
                (fixture/'Package.swift').write_text(original.replace('"603.0.2"..<"605.0.0"',f'"{lo}"..<"{hi}"'))
                with self.assertRaisesRegex(ValueError,'reviewed'):guard.check(fixture)
            (fixture/'Package.swift').write_text(original)
            for version,accepted in (('603.0.1',False),('603.0.2',True),('604.0.0',True),('605.0.0',False)):
                for name in guard.LIVE_LOCKS:
                    path=fixture/name;lock=json.loads(path.read_text())
                    next(pin['state'] for pin in lock['pins'] if pin['identity']=='swift-syntax')['version']=version
                    path.write_text(json.dumps(lock))
                if accepted:guard.check(fixture)
                else:
                    with self.assertRaisesRegex(ValueError,'outside'):guard.check(fixture)

    def test_forward_toolchain_is_in_both_aggregate_inventories(self):
        bridge=load('legacy-ci-results');adapter=load('router_ci_adapter')
        name='forward toolchain (Xcode 27)'
        self.assertIn(name,bridge.LEGACY['.github/workflows/principle-gates.yml'])
        self.assertIn('Test the supported SwiftSyntax floor',adapter.LEGACY['principle-gates.yml'][1][name])
        source=(ROOT/'.github/workflows/principle-gates.yml').read_text().split('  xcode-27:\n')[1]
        self.assertIn("github.workflow != 'principle-gates' || vars.INNOROUTER_CI_AGGREGATE != 'true'",source)
        self.assertIn('ref: ${{ inputs.ref || github.sha }}',source)
        self.assertIn('persist-credentials: false',source)
        for step in ('Test with the committed resolution','Test macros with the newest admitted swift-syntax',
                     'Build the macro-first consumer with library evolution','Test the supported SwiftSyntax floor'):
            self.assertIn('- name: '+step,source)

    def test_recovery_cannot_cancel_native_main_validation(self):
        ci=(ROOT/'.github/workflows/ci.yml').read_text()
        self.assertIn("format('dependabot-{0}', inputs.dependabot_merge_pr) || 'validation'",ci)
        for name in ('principle-gates','platforms','coverage','docs-ci','sanitizers','performance-smoke','migration-smoke'):
            source=(ROOT/'.github/workflows'/f'{name}.yml').read_text()
            group=re.search(r'^  group: (.*)$',source,re.M)[1]
            self.assertIn('${{ github.run_id }}',group)

    def test_candidate_identity_and_source_links(self):
        candidate=load('validate-release-candidate')
        for version in ('6.1.0','6.1.1','7.0.0-rc.1'):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temp:
                fixture,sha,git,_=candidate_fixture(Path(temp)/'release',version)
                metadata=candidate.validate(fixture,version,sha)
                self.assertEqual(metadata['commit_sha'],sha)
                tags=git('tag')
                for wrong,revision in [('v'+version,sha),('99.0.0',sha),(version,'main'),(version,'A'*40),(version,'0'*40)]:
                    with self.assertRaises((ValueError,subprocess.CalledProcessError)):
                        candidate.validate(fixture,wrong,revision)
                self.assertEqual(git('tag'),tags)
                resolve=fixture/'scripts/resolve-docc-source-ref.sh'
                self.assertEqual(subprocess.check_output(['bash',str(resolve),version,'',sha],text=True).strip(),sha)
                for value in ('main','a'*39,'A'*40,'x;touch /tmp/invalid'):
                    self.assertNotEqual(subprocess.run(['bash',str(resolve),version,'',value],capture_output=True).returncode,0)
                # A normal development Unreleased entry does not invalidate the
                # earlier exact-SHA cut or turn it into current HEAD validation.
                (fixture/'CHANGELOG.md').write_text('# Changelog\n\n## Unreleased\n\n- New development note.\n')
                git('add','.');git('commit','-qm','normal development notes')
                self.assertEqual(candidate.validate(fixture,version,sha)['commit_sha'],sha)

    def test_release_preflight_defaults_to_tagless_candidate(self):
        source=(ROOT/'.github/workflows/release.yml').read_text()
        step=source.split('      - name: Validate release request\n')[1].split('      - name: Resolve exact tag commit')[0]
        script=step.split('        run: |\n')[1]
        script='\n'.join(line[10:] if line.startswith('          ') else line for line in script.splitlines())
        with tempfile.TemporaryDirectory() as temp:
            fixture,sha,git,env=candidate_fixture(Path(temp)/'repository','6.1.1')
            base={**env,'RELEASE_EVENT':'workflow_dispatch','RELEASE_DISPATCH_REF':'refs/heads/main',
                  'RELEASE_TAG':'','RELEASE_VERSION':'6.1.1','RELEASE_COMMIT_SHA':sha,
                  'RELEASE_PUBLISH':'false','RELEASE_PRERELEASE':'false'}
            output=Path(temp)/'output'
            def execute(changes):
                output.write_text('')
                return subprocess.run(['bash','-c',script],cwd=fixture,
                    env={**base,**changes,'GITHUB_OUTPUT':str(output)},capture_output=True,text=True)
            result=execute({});self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('publish=false\n',output.read_text())
            self.assertIn('candidate=true\n',output.read_text())
            for changes in ({'RELEASE_DISPATCH_REF':'refs/heads/topic'}, {'RELEASE_TAG':'6.1.1'},
                            {'RELEASE_VERSION':''}, {'RELEASE_COMMIT_SHA':'main'}, {'RELEASE_PUBLISH':'true'}):
                self.assertNotEqual(execute(changes).returncode,0,changes)
            self.assertEqual(execute({'RELEASE_PUBLISH':'true','RELEASE_TAG':'6.1.1',
                                     'RELEASE_VERSION':'','RELEASE_COMMIT_SHA':''}).returncode,0)
            self.assertIn('candidate=false\n',output.read_text())
            self.assertEqual(execute({'RELEASE_EVENT':'push','RELEASE_TAG':'6.1.1-rc.1',
                                     'RELEASE_VERSION':'','RELEASE_COMMIT_SHA':''}).returncode,0)
            self.assertIn('validate=false\n',output.read_text())
            # Valid identity alone cannot authorize an unmerged topic commit.
            (fixture/'CHANGELOG.md').write_text('# Changelog\n\n## Unreleased\n\n- Normal development note.\n')
            git('add','.');git('commit','-qm','normal development notes')
            self.assertEqual(execute({}).returncode,0)
            self.assertNotEqual(execute({'RELEASE_COMMIT_SHA':git('rev-parse','HEAD')}).returncode,0)

    def test_pr_workflows_preserve_router_gates_and_privilege_boundaries(self):
        workflows=ROOT/'.github/workflows'
        for name in ('ci.yml','principle-gates.yml','docs-ci.yml','platforms.yml','coverage.yml',
                     'sanitizers.yml','performance-smoke.yml','migration-smoke.yml'):
            source=(workflows/name).read_text()
            self.assertNotIn('pull_request_target',source)
            self.assertNotIn('contents: write',source)
            self.assertNotIn('continue-on-error:',source)
            self.assertNotIn('    paths:',source)
            self.assertNotIn('secrets.',source)
        ci=(workflows/'ci.yml').read_text()
        for job in ('core','docc','platforms','coverage','sanitizers','performance','migration'):
            self.assertIn('  '+job+':\n    name: CI '+job+'\n',ci)
        platforms=(workflows/'platforms.yml').read_text()
        for expected in ('minimumPassedTests: 12','minimumPassedTests: 6','minimumPassedTests: 10',
                         'RouterInspectorProbe','RouterCatalystPlatformTests','run_simulator.sh',
                         'check-inspector-ui-results.py','Platforms Required','fail-fast: false'):
            self.assertIn(expected,platforms)
        for name in ('platforms.yml','sanitizers.yml'):
            before,required=(workflows/name).read_text().rsplit('  required:\n',1)
            self.assertNotIn("github.workflow == 'release'",before)
            self.assertIn('ref: ${{ inputs.ref || github.sha }}',before)
            self.assertIn("github.workflow == 'release' && 'refs/heads/main'",required)
        coverage=(workflows/'coverage.yml').read_text()
        self.assertIn('--minimum-line-coverage 85',coverage)
        self.assertIn('--minimum-line-coverage 83',coverage)
        self.assertIn('--no-parallel',coverage)
        self.assertNotIn('id-token: write',coverage.split('  codecov:')[0])
        self.assertIn("github.ref == 'refs/heads/main'",coverage.split('  codecov:')[1])
        self.assertIn("github.event.inputs.dependabot_merge_pr",coverage.split('  codecov:')[1])
        release=(workflows/'release.yml').read_text()
        self.assertIn('      publish:',release)
        self.assertIn('        default: false',release.split('      publish:')[1].split('      prerelease:')[0])
        for job in ('publish-gh-pages','create-release'):
            text=release.split('  '+job+':')[1]
            self.assertIn("if: needs.preflight.outputs.publish == 'true'",text)
            self.assertIn('- candidate-required',text)
        self.assertNotIn('git tag ',release)
        self.assertIn('Candidate Required',release)

    def test_transition_dependency_evaluator_is_fail_closed(self):
        policy=load('ci-policy')
        plan=policy.make_plan('pull_request',{'action':'opened','pull_request':{'labels':[]}},['README.md'])
        needs={job:{'result':'success' if job in ('ci-plan','policy','documentation') else 'skipped'} for job in ('ci-plan',*policy.JOBS)}
        env={**os.environ,'CI_PLAN':json.dumps(plan),'CI_NEEDS':json.dumps(needs)}
        command=['python3',str(ROOT/'scripts/evaluate-transition.py')]
        self.assertEqual(subprocess.run(command,env=env,capture_output=True).returncode,0)
        for job in needs:
            bad=json.loads(json.dumps(needs));bad[job]['result']='cancelled'
            self.assertNotEqual(subprocess.run(command,env={**env,'CI_NEEDS':json.dumps(bad)},capture_output=True).returncode,0)


if __name__=='__main__':unittest.main()
