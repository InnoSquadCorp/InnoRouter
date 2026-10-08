"""Executable build/skip wiring with real Git anchors and fake tool execution."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('execution',ROOT/'scripts/ci_product_execution.py')
execution=importlib.util.module_from_spec(spec);spec.loader.exec_module(execution)
GRAPH=json.loads((ROOT/'scripts/ci-product-graph.json').read_text())
REPO='InnoFlow' if 'InnoFlow' in GRAPH['products'] else 'InnoRouter'

def dump_graph(graph):
    targets=[]
    for name,target in graph['targets'].items():
        inputs=target['inputs'];path=inputs[0].rstrip('/') if inputs[0].endswith('/') else inputs[0].rsplit('/',1)[0]
        item={'name':name,'type':target['kind'],'path':path,'dependencies':[{'target':[name,None]} for name in target['dependencies']]}
        if not inputs[0].endswith('/'):item['sources']=[x[len(path)+1:] for x in inputs]
        targets.append(item)
    return {'targets':targets,'products':[{'name':name,'targets':targets} for name,targets in graph['products'].items()]}

class ProductExecutionTests(unittest.TestCase):
    def setUp(self):
        tmp=tempfile.TemporaryDirectory();self.addCleanup(tmp.cleanup);self.root=Path(tmp.name)
        self.git_env={**os.environ,'GIT_AUTHOR_NAME':'Fixture','GIT_COMMITTER_NAME':'Fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid','GIT_COMMITTER_EMAIL':'fixture@example.invalid'}
        self.git('init','-q','-b','main')
        (self.root/'scripts').mkdir()
        shutil.copyfile(ROOT/'scripts/ci-product-graph.json',self.root/'scripts/ci-product-graph.json')
        shutil.copyfile(ROOT/'Package.swift',self.root/'Package.swift')
        (self.root/'Package.resolved').write_text('{}\n')
        self.base=self.commit()
        source=self.root/'Sources'/(REPO+'Inspector')/'Changed.swift';source.parent.mkdir(parents=True);source.write_text('struct Changed {}\n')
        self.head=self.commit()
        self.event={'action':'synchronize','pull_request':{'base':{'sha':self.base},'head':{'sha':self.head},'user':{'login':'contributor'},'labels':[]}}
        self.event_file=self.root/'event.json';self.event_file.write_text(json.dumps(self.event))
        self.env={'PRODUCT_SCOPE_ENABLED':'true','GITHUB_EVENT_NAME':'pull_request','GITHUB_EVENT_PATH':str(self.event_file),'GITHUB_SHA':self.head}
        self.commands=[]
    def git(self,*args):return subprocess.check_output(['git','-C',str(self.root),'-c','commit.gpgsign=false',*args],env=self.git_env,text=True).strip()
    def commit(self):self.git('add','-A');self.git('commit','-qm','fixture');return self.git('rev-parse','HEAD')
    def dump(self,args,**kwargs):
        self.assertEqual(args[:4],['xcrun','swift','package','--package-path'])
        self.assertEqual(args[-1],'dump-package');return json.dumps(dump_graph(GRAPH))
    def fake_run(self,command,**kwargs):self.commands.append(command);self.assertTrue(kwargs['check'])
    def test_exact_pr_native_target_admission(self):
        plan=execution.admit(self.root,self.env,self.dump)
        self.assertEqual(plan['mode'],'scoped');self.assertIn(REPO+'Inspector',plan['products'])
        self.assertNotIn('InnoFlowMacros',plan['targets'])
    def test_disabled_release_bot_main_queue_manual_dirty_wrong_sha_full(self):
        for env in ({**self.env,'PRODUCT_SCOPE_ENABLED':'false'},{**self.env,'GITHUB_SHA':'a'*40},
                    *[{**self.env,'GITHUB_EVENT_NAME':event} for event in ('push','merge_group','workflow_dispatch')]):
            self.assertEqual(execution.admit(self.root,env,self.dump)['mode'],'full')
        for field,value in [('labels',[{'name':'Release-Validation'}]),('user',{'login':'dependabot[bot]'})]:
            event=copy.deepcopy(self.event);event['pull_request'][field]=value;self.event_file.write_text(json.dumps(event))
            self.assertEqual(execution.admit(self.root,self.env,self.dump)['mode'],'full')
        self.event_file.write_text(json.dumps(self.event));(self.root/'Package.swift').write_text('// dirty\n')
        self.assertEqual(execution.admit(self.root,self.env,self.dump)['mode'],'full')
    def test_diff_and_runtime_graph_failure_run_full(self):
        with mock.patch.object(execution.impact,'diff_paths',side_effect=ValueError('missing diff')):
            self.assertEqual(execution.admit(self.root,self.env,self.dump)['mode'],'full')
        self.assertEqual(execution.admit(self.root,self.env,lambda *a,**k:'{}')['mode'],'full')
        with mock.patch.object(execution.impact,'select',return_value={'mode':'full'}):
            self.assertEqual(execution.admit(self.root,self.env,self.dump)['mode'],'full')
    def test_native_flow_commands_execute_then_verified_receipt(self):
        receipts=self.root/'receipts';temporary=self.root/'temp'
        proof=execution.execute(self.root,self.env,'flow-platform','macOS','macOS',temporary,receipts,self.fake_run,self.dump)
        self.assertEqual(proof['decision'],'run-scoped');self.assertTrue(self.commands)
        for command in self.commands:
            self.assertEqual(command[:3],['xcrun','swift','build']);self.assertIn('--target',command)
            self.assertIn('--force-resolved-versions',command);self.assertNotIn('--filter',command)
        execution.verify(self.root,self.env,'flow-platform',['macOS'],'macOS',temporary,receipts,self.dump)
        with self.assertRaises(ValueError):execution.execute(self.root,self.env,'flow-platform','macOS','macOS',temporary,receipts,self.fake_run,self.dump)
    def test_other_flow_platforms_and_default_use_original_xcode_build(self):
        plan=execution.admit(self.root,self.env,self.dump)
        for platform in execution.FLOW_PLATFORMS:
            full={**plan,'mode':'full'}
            command=execution.recipe(self.root,full,'flow-platform',platform,platform,self.root/'tmp')
            self.assertEqual(command['decision'],'run-full');self.assertEqual(command['commands'][0][0],'xcodebuild')
            self.assertIn('InnoFlow-Package',command['commands'][0])
            if platform!='macOS':self.assertEqual(execution.recipe(self.root,plan,'flow-platform',platform,platform,self.root/'tmp')['decision'],'run-full')
    def test_router_unaffected_skip_and_developer_consumer_stays_required(self):
        plan={'mode':'scoped','products':['InnoRouterInspector','InnoRouterTesting'], 'affected_targets':['InnoRouterInspector','InnoRouterTesting','InnoRouterDeveloperToolsSmoke']}
        first=execution.recipe(self.root,plan,'router-consumer','InnoRouterMacroFirstSmoke','iOS',self.root/'tmp')
        second=execution.recipe(self.root,plan,'router-consumer','InnoRouterDeveloperToolsSmoke','iOS',self.root/'tmp')
        self.assertEqual(first,{'decision':'skip-unaffected','commands':[]})
        self.assertEqual(second['decision'],'run-selected-consumer');self.assertIn('BUILD_LIBRARY_FOR_DISTRIBUTION=YES',second['commands'][0])
        full=execution.recipe(self.root,{**plan,'mode':'full'},'router-consumer','InnoRouterMacroFirstSmoke','iOS',self.root/'tmp')
        self.assertEqual(full['decision'],'run-full')
    def test_failure_never_writes_success_and_missing_receipt_fails(self):
        def fail(command,**kwargs):raise subprocess.CalledProcessError(1,command)
        receipts=self.root/'receipts'
        with self.assertRaises(subprocess.CalledProcessError):execution.execute(self.root,self.env,'flow-platform','macOS','macOS',self.root/'tmp',receipts,fail,self.dump)
        self.assertFalse(list(receipts.glob('*')))
        with self.assertRaises(OSError):execution.verify(self.root,self.env,'flow-platform',['macOS'],'macOS',self.root/'tmp',receipts,self.dump)
    def test_forged_receipt_unknown_platform_duplicate_and_skip_fail_closed(self):
        receipts=self.root/'receipts';temporary=self.root/'tmp'
        proof=execution.execute(self.root,self.env,'flow-platform','macOS','macOS',temporary,receipts,self.fake_run,self.dump)
        path=execution.receipt_path(receipts,'flow-platform','macOS','macOS')
        for key,value in [('decision','skip-unaffected'),('result','skipped'),('commands',[])]:
            path.write_text(json.dumps({**proof,key:value}))
            with self.assertRaises(ValueError):execution.verify(self.root,self.env,'flow-platform',['macOS'],'macOS',temporary,receipts,self.dump)
        with self.assertRaises(ValueError):execution.recipe(self.root,proof['admission'],'flow-platform','Linux','Linux',temporary)
        with self.assertRaises(ValueError):execution.verify(self.root,self.env,'flow-platform',['macOS','macOS'],'macOS',temporary,receipts,self.dump)
    def test_executable_source_mode_forces_full(self):
        source = next((self.root/'Sources').rglob('Changed.swift'))
        source.chmod(0o755)
        self.git('add', str(source.relative_to(self.root)))
        self.git('commit', '-qm', 'mode change')
        head = self.git('rev-parse', 'HEAD')
        self.event['pull_request']['head']['sha'] = head
        self.event_file.write_text(json.dumps(self.event))
        env = {**self.env, 'GITHUB_SHA': head}
        self.assertEqual(self.git('status', '--porcelain', '--untracked-files=no'), '')
        with self.assertRaises(ValueError):
            execution.regular_source_diff(self.root, self.base, head)
        self.assertEqual(execution.admit(self.root, env, self.dump)['mode'], 'full')
    def test_untracked_target_input_cannot_enter_narrow_admission(self):
        target = next(entry for entry in GRAPH['targets'].values() if entry['kind'] == 'regular')
        path = target.get('path') or target['inputs'][0].rstrip('/')
        injected = self.root / path / 'Injected.swift'
        injected.parent.mkdir(parents=True, exist_ok=True)
        injected.write_text('struct Injected {}\n')
        result = execution.admit(self.root, self.env, self.dump)
        self.assertEqual(result['mode'], 'full')
        self.assertIn('untracked source/resource/consumer', result['reason'])

    def test_existing_but_untracked_lock_cannot_authorize_narrow_build(self):
        lock = self.root/'Package.resolved'
        if not lock.exists(): return  # Protobuf has no narrow path at all.
        self.git('rm', '--cached', 'Package.resolved')
        self.git('commit', '-qm', 'untrack lock')
        base = self.git('rev-parse', 'HEAD')
        source = next((self.root/'Sources').rglob('Changed.swift'))
        source.write_text('struct Changed { let value = 1 }\n')
        self.git('add', str(source.relative_to(self.root)))
        self.git('commit', '-qm', 'ordinary source change after lock removal')
        head = self.git('rev-parse', 'HEAD')
        event = copy.deepcopy(self.event)
        event['pull_request'].update(base={'sha':base},head={'sha':head})
        self.event_file.write_text(json.dumps(event))
        with mock.patch.object(execution, 'git', wraps=execution.git) as observed:
            result = execution.admit(self.root, {**self.env,'GITHUB_SHA':head}, self.dump)
        self.assertEqual(result['mode'], 'full')
        self.assertTrue(any(call.args[1:] == ('ls-files','--error-unmatch','Package.resolved') for call in observed.call_args_list))

    def test_workflow_wiring_keeps_full_test_fallback_and_required_names(self):
        ci=(ROOT/'.github/workflows/ci.yml').read_text()
        if REPO=='InnoFlow':
            builds=ci.split('\n  package-builds:\n',1)[1].split('\n  focused-runtime-tests:',1)[0]
            self.assertIn('vars.INNOFLOW_PRODUCT_CI',builds);self.assertIn('fetch-depth: 0',builds)
            self.assertIn('ci_product_execution.py build',builds);self.assertIn('ci_product_execution.py verify',builds)
            tests=ci.split('\n  tests:\n',1)[1].split('\n  release-tests:',1)[0]
            self.assertIn('--no-parallel',tests);self.assertNotIn('--filter',tests)
        else:
            platforms=(ROOT/'.github/workflows/platforms.yml').read_text()
            builds=platforms.split('\n  build-matrix:\n',1)[1].split('\n  platform-tests:',1)[0]
            self.assertIn("vars.INNOROUTER_CI_AGGREGATE == 'true'",builds)
            self.assertIn('vars.INNOROUTER_PRODUCT_CI',builds)
            self.assertEqual(builds.count('ci_product_execution.py build'),2);self.assertEqual(builds.count('ci_product_execution.py verify'),2)
            self.assertIn('./scripts/check-platform-interface.sh',builds)
            gates=(ROOT/'.github/workflows/principle-gates.yml').read_text()
            self.assertIn('swift test --jobs 2 --no-parallel',gates)

if __name__=='__main__':unittest.main()
