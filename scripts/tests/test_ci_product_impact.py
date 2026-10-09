"""Planning-only graph controls; no Swift or Xcode command is executed."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('impact', ROOT/'scripts/ci-product-impact.py')
impact = importlib.util.module_from_spec(spec); spec.loader.exec_module(impact)
GRAPH = json.loads((ROOT/'scripts/ci-product-graph.json').read_text())
REPO = 'InnoFlow' if 'InnoFlow' in GRAPH['products'] else 'InnoRouter'

class ProductImpactTests(unittest.TestCase):
    def test_manifest_bound_complete_static_inventory(self):
        impact.validate(GRAPH)
        manifest = (ROOT/'Package.swift').read_text()
        self.assertEqual(hashlib.sha256(manifest.encode()).hexdigest(), GRAPH['manifest_sha256'])
        self.assertEqual(len(GRAPH['targets']), 8 if REPO=='InnoFlow' else 26)
        for name, target in GRAPH['targets'].items():
            self.assertIn('name: "'+name+'"', manifest)
            for path in target['inputs']: self.assertTrue((ROOT/path).exists(),path)
        for consumer in GRAPH['consumers'].values():
            self.assertTrue((ROOT/consumer['path']/'Package.swift').is_file())
    def test_inspector_reverse_dependencies_and_wide_test_compile_closure(self):
        result = impact.select(GRAPH, ['Sources/'+REPO+'Inspector/File.swift'])
        expected = [REPO+'Inspector'] if REPO=='InnoFlow' else [REPO+'Inspector',REPO+'Testing']
        self.assertEqual(result['affected_products'], expected)
        self.assertEqual(result['test_dependency_products'], sorted(GRAPH['products']))
        self.assertEqual(result['mode'], 'scoped-build-plan')
        self.assertTrue(result['consumers'])
        self.assertEqual(result['execution'], 'planning only; existing required/platform/release gates unchanged')
    def test_core_macros_manifest_unknown_resource_and_generated_full(self):
        for name in GRAPH['full_targets']:
            target=GRAPH['targets'][name]
            self.assertEqual(impact.select(GRAPH,[target['inputs'][0]+'Changed.swift'])['mode'],'full')
        for path in ('Package.swift','Package.resolved','.github/workflows/ci.yml','scripts/ci-policy.py',
                     'Unknown/File.swift','Sources/'+REPO+'Inspector/PrivacyInfo.xcprivacy',
                     'Sources/'+REPO+'Inspector/Generated/Model.swift','Sources/'+REPO+'Inspector/Message.pb.swift',
                     'Tests/'+REPO+'Tests/Fixtures/Package.swift'):
            self.assertEqual(impact.select(GRAPH,[path])['mode'],'full',path)
        self.assertEqual(impact.select(GRAPH,[])['mode'],'full')
        self.assertEqual(impact.select(GRAPH,['Sources/'+REPO+'Inspector/X.swift'],'0'*64)['mode'],'full')
    def test_mixed_changes_unions_reverse_dependencies_or_full(self):
        result=impact.select(GRAPH,['Sources/'+REPO+'Inspector/File.swift','Sources/'+REPO+'Testing/File.swift'])
        self.assertIn(REPO+'Inspector',result['affected_products'])
        self.assertIn(REPO+'Testing',result['affected_products'])
        self.assertEqual(impact.select(GRAPH,['Sources/'+REPO+'Inspector/File.swift','README.md'])['mode'],'full')
    def test_native_build_commands_are_isolated_and_tests_keep_serial_full_scope(self):
        result=impact.select(GRAPH,['Sources/'+REPO+'Inspector/File.swift'])
        paths=[]
        for command in result['native_build_commands']:
            self.assertEqual(command[:2],['swift','build']);self.assertIn('--target',command)
            paths.append(command[command.index('--scratch-path')+1])
        self.assertEqual(len(paths),len(set(paths)))
        self.assertIn('--no-parallel',result['test_command'])
        self.assertNotIn('--parallel',result['test_command']);self.assertNotIn('--filter',result['test_command'])
        self.assertIn('full package',result['test_compilation_scope'])
    def test_graph_corruption_rejected(self):
        name=next(iter(GRAPH['targets']))
        mutations=[lambda g:g.update(schema=True),lambda g:g.update(extra=1),
                   lambda g:g['targets'][name]['dependencies'].append('unknown'),
                   lambda g:g['targets'][name]['dependencies'].append(name),
                   lambda g:g['targets'][name].update(kind='unreviewed'),
                   lambda g:g['products'].update(Fake=['unknown']),
                   lambda g:g['targets'][name].update(inputs=['../outside/'])]
        for mutate in mutations:
            graph=copy.deepcopy(GRAPH);mutate(graph)
            with self.assertRaises(ValueError):impact.validate(graph)
    def test_dump_validation_detects_inventory_and_dependency_drift(self):
        dump={'targets':[],'products':[{'name':n,'targets':t} for n,t in GRAPH['products'].items()]}
        for name,target in GRAPH['targets'].items():
            inputs=target['inputs'];prefix=inputs[0].rsplit('/',1)[0] if not inputs[0].endswith('/') else inputs[0].rstrip('/')
            item={'name':name,'type':target['kind'],'path':prefix,
                  'dependencies':[{'target':[dep,None]} for dep in target['dependencies']]}
            if not inputs[0].endswith('/'):item['sources']=[path[len(prefix)+1:] for path in inputs]
            dump['targets'].append(item)
        impact.verify_dump(GRAPH,dump)
        for mutate in (lambda d:d['targets'].pop(),lambda d:d['products'].pop(),
                       lambda d:d['targets'][0].update(type='unknown'),
                       lambda d:d['targets'][0]['dependencies'].append({'target':['unknown',None]})):
            bad=copy.deepcopy(dump);mutate(bad)
            with self.assertRaises(ValueError):impact.verify_dump(GRAPH,bad)
    def test_cli_diff_failure_returns_full_planning_only(self):
        proc=subprocess.run(['python3',str(ROOT/'scripts/ci-product-impact.py'),'--root',str(ROOT),
                             '--base','0'*40,'--head','1'*40],capture_output=True,text=True)
        self.assertEqual(proc.returncode,0,proc.stderr)
        result=json.loads(proc.stdout)
        self.assertEqual(result['mode'],'full')
        self.assertIn('planning only',result['execution'])

if __name__=='__main__':unittest.main()
