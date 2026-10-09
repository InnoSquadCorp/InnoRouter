"""Prose is a content proof, never a suffix-only license to skip compilation."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module
prose = load('prose', 'ci_prose_impact.py')
policy = load('policy', 'ci-policy.py')

class ProseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_AUTHOR_NAME='Fixture', GIT_COMMITTER_NAME='Fixture',
                        GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_EMAIL='fixture@example.invalid')
        self.git('init', '-q', '-b', 'main')
        self.write('README.md', '# Example\n\nOld prose\n\n```swift\nlet a = 1\n```\n')
        self.base = self.commit()
    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), '-c', 'commit.gpgsign=false', *args],
                                       env=self.env, text=True).strip()
    def write(self, path, text):
        file = self.root / path; file.parent.mkdir(parents=True, exist_ok=True); file.write_text(text)
    def commit(self):
        self.git('add', '-A'); self.git('commit', '-qm', 'fixture'); return self.git('rev-parse', 'HEAD')
    def event(self, head, labels=()):
        return {'action': 'synchronize', 'pull_request': {'labels': [{'name': x} for x in labels],
                'user': {'login': 'contributor'}, 'base': {'sha': self.base}, 'head': {'sha': head}}}
    def plan(self, head, labels=()):
        event = self.event(head, labels)
        return policy.make_plan('pull_request', event, policy.changed_paths(self.root, self.base, head),
                                prose.prove(self.root, self.base, head))
    def pure_head(self):
        self.write('README.md', (self.root / 'README.md').read_text().replace('Old prose', 'Updated prose'))
        return self.commit()
    def test_prose_keeps_fences_and_selects_only_static_existing_contexts(self):
        head = self.pure_head(); plan = self.plan(head)
        expected = {'policy', 'docs-required'} if 'docs-required' in policy.JOBS else {'policy'}
        self.assertEqual({j for j, v in plan['jobs'].items() if v}, expected)
        prose.revalidate(plan['prose'], self.root, 'pull_request', self.event(head))
        policy.validate_plan(plan)
        needs = {'ci-plan': {'result': 'success'}, **{j: {'result': 'success' if v else 'skipped'} for j,v in plan['jobs'].items()}}
        policy.evaluate(plan, needs)
        for job in policy.JOBS:
            bad = copy.deepcopy(needs); bad[job]['result'] = 'cancelled'
            with self.subTest(job=job), self.assertRaises(ValueError): policy.evaluate(plan, bad)
    def test_docc_symbol_links_require_compiler_validation(self):
        self.assertFalse(prose.eligible("Sources/InnoRouterUmbrella/InnoRouter.docc/Guide.md"))
        self.write("Sources/InnoRouterUmbrella/InnoRouter.docc/Guide.md", "# Guide\nSee ``UnknownSymbol``\n")
        self.assertNotIn("prose", self.plan(self.commit()))
    def test_funding_only_can_skip_compilation(self):
        self.write('.github/FUNDING.yml', 'github: [InnoSquadCorp]\ncustom: ["https://example.com"]\n')
        plan = self.plan(self.commit())
        self.assertIn('prose', plan)
    def test_funding_malformed_and_aliases_rejected(self):
        for value in ('[broken', '"unterminated', '&alias value', '{x: y}', 'a, b'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                prose.funding_safe('github: ' + value + '\n')
    def test_fence_body_language_and_removal_never_get_prose_proof(self):
        text = (self.root/'README.md').read_text()
        for changed in (text.replace('a = 1', 'a = 2'), text.replace('```swift', '```shell'),
                        '# Example\nOld prose\n', text + '\n~~~bash\necho hi\n~~~\n'):
            self.write('README.md', changed); head = self.commit()
            self.assertIsNone(prose.prove(self.root, self.base, head))
    def test_inline_code_indent_html_directive_and_frontmatter_conservative(self):
        text = (self.root/'README.md').read_text()
        for addition in ('`code`\n', '    indented\n', '<script>do()</script>\n', '@Snippet(path: "x")\n',
                         '---\n', '{% include x %}\n', '{{ generator }}\n', '> nested blockquote\n', 'Version 6.0.1\n'):
            self.write('README.md', text + addition); head = self.commit()
            self.assertIsNone(prose.prove(self.root, self.base, head))
    def test_sensitive_paths_unknown_mixed_source_and_manifest(self):
        for path in ('CHANGELOG.md', 'RELEASING.md', 'AGENTS.md', 'CLAUDE.md', 'SECURITY.md', 'Package.swift',
                     'Package.resolved', 'Sources/X/README.md', 'Tests/README.md', '.github/workflows/ci.yml',
                     'docs/contracts/guide.md', 'Docs/release-checklist.md', 'Tools/generator.swift',
                     'Plugins/Anything.swift', 'unknown.md', 'docs/something.swift'):
            self.write(path, 'change\n'); head = self.commit()
            self.assertIsNone(prose.prove(self.root, self.base, head), path)
            self.git('reset', '--hard', self.base)
    def test_release_labels_bot_and_non_pr_events_never_skip(self):
        head = self.pure_head(); proof = prose.prove(self.root, self.base, head)
        self.assertTrue(all(self.plan(head, ['release-validation'])['jobs'].values()))
        event = self.event(head); event['pull_request']['user']['login'] = 'dependabot[bot]'
        self.assertTrue(all(policy.make_plan('pull_request', event, ['README.md'], proof)['jobs'].values()))
        for name, event in [('push', {'ref': 'refs/heads/main'}), ('merge_group', {'action':'checks_requested'}), ('workflow_dispatch', {})]:
            self.assertTrue(all(policy.make_plan(name, event, ['README.md'], proof)['jobs'].values()))
    def test_plan_proof_tampering_and_event_identity(self):
        head = self.pure_head(); plan = self.plan(head)
        for change in (lambda p: p['prose']['paths'].append('Package.swift'),
                       lambda p: p['prose'].update(extra=True), lambda p: p['prose'].update(base='HEAD'),
                       lambda p: p.update(lane='full'), lambda p: p['jobs'].update(policy=False)):
            bad = copy.deepcopy(plan); change(bad)
            with self.assertRaises(ValueError): policy.validate_plan(bad)
        for event in (self.event(self.base), {**self.event(head), 'pull_request':{**self.event(head)['pull_request'], 'base':{'sha':head}}}):
            with self.assertRaises(ValueError): prose.revalidate(plan['prose'], self.root, 'pull_request', event)
    def test_forged_content_proof_fails_revalidation(self):
        head = self.pure_head(); proof = prose.prove(self.root, self.base, head)
        self.write('README.md', '```swift\nmalicious()\n```\n'); new = self.commit()
        proof['head'] = new
        with self.assertRaises(ValueError): prose.revalidate(proof, self.root, 'pull_request', self.event(new))
    def test_symlinks_executable_mode_binary_and_conflict_fail_closed(self):
        self.git('update-index', '--chmod=+x', 'README.md'); self.git('commit', '-qm', 'mode')
        with self.assertRaises(ValueError): prose.prove(self.root, self.base, self.git('rev-parse','HEAD'))
        self.git('reset','--hard',self.base)
        (self.root/'README.md').unlink(); (self.root/'README.md').symlink_to('Package.swift'); head=self.commit()
        self.assertIsNone(prose.prove(self.root,self.base,head))
        self.git('reset','--hard',self.base)
        for content in ('bad\x00data','<<<<<<< unresolved\n', '```swift\nunterminated\n'):
            self.write('README.md', content); head=self.commit()
            with self.assertRaises(ValueError): prose.prove(self.root,self.base,head)
    def test_new_deleted_and_renamed_source_cannot_hide(self):
        self.write('docs/guide.md','Just prose\n'); head=self.commit()
        self.assertIsNotNone(prose.prove(self.root,self.base,head))
        self.git('reset','--hard',self.base)
        self.write('Sources/Code.swift','struct Code {}\n'); base=self.commit()
        (self.root/'Sources/Code.swift').rename(self.root/'docs.md'); head=self.commit()
        self.assertIsNone(prose.prove(self.root,base,head))
    def test_cli_missing_git_diff_selects_full_and_check_rejects_forgery(self):
        head=self.pure_head(); event=self.event(head)
        event_file=self.root/'event.json'; output=self.root/'plan.json'
        event_file.write_text(json.dumps(event))
        env={**self.env,'GITHUB_EVENT_NAME':'pull_request','GITHUB_EVENT_PATH':str(event_file)}
        command=['python3',str(ROOT/'scripts/ci-policy.py'),'plan','--event',str(event_file),'--root',str(self.root),'--output',str(output)]
        result=subprocess.run(command,env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        plan=json.loads(output.read_text()); self.assertIn('prose',plan)
        result=subprocess.run(['python3',str(ROOT/'scripts/ci-policy.py'),'check-prose'],cwd=self.root,
                              env={**env,'CI_PLAN':json.dumps(plan)},capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        event['pull_request']['head']['sha']='1'*40; event_file.write_text(json.dumps(event))
        result=subprocess.run(command,env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(all(json.loads(output.read_text())['jobs'].values()))
        result=subprocess.run(['python3',str(ROOT/'scripts/ci-policy.py'),'check-prose'],cwd=self.root,
                              env={**env,'CI_PLAN':json.dumps(plan)},capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)

if __name__=='__main__': unittest.main()
