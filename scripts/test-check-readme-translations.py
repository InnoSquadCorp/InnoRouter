#!/usr/bin/env python3
"""Regression tests for the static translation gate, without Swift or network."""
import importlib.util
import os
import subprocess
import sys
from unittest import mock
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('readme_check', ROOT / 'scripts/check-readme-translations.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ReadmeContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='innorouter-readmes-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path in ROOT.iterdir():
            if path.name in checker.FILES:
                (self.root / path.name).write_text(path.read_text(encoding='utf-8'), encoding='utf-8')
            elif path.name != '.git':
                (self.root / path.name).symlink_to(path, target_is_directory=path.is_dir())

    def mutate(self, old, new):
        path = self.root / 'README.es.md'
        text = path.read_text(encoding='utf-8')
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding='utf-8')

    def test_ascii_locale_without_utf8_coercion(self):
        env = dict(os.environ, LC_ALL='C', PYTHONUTF8='0', PYTHONCOERCECLOCALE='0')
        result = subprocess.run(
            [sys.executable, str(ROOT / 'scripts/check-readme-translations.py'),
             '--root', str(self.root)], env=env, capture_output=True,
            text=True, encoding='utf-8', timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_unreadable_version(self, filename, message):
        original = Path.read_text
        def changed_source(path, *args, **kwargs):
            if path.name == filename:
                return '// declaration formatting changed'
            return original(path, *args, **kwargs)
        with mock.patch.object(Path, 'read_text', changed_source):
            self.assertEqual(checker.check(self.root), [message])

    def test_missing_runtime_version_pattern_is_diagnostic(self):
        self.assert_unreadable_version(
            'InnoRouterVersion.swift',
            'InnoRouterVersion.swift: cannot read the current runtime version',
        )

    def test_missing_fixture_version_pattern_is_diagnostic(self):
        self.assert_unreadable_version(
            'RouterScenarioFixture.swift',
            'RouterScenarioFixture.swift: cannot read the current fixture format version',
        )

    def test_runtime_model_heading_is_preserved(self):
        path = self.root / 'README.md'
        text = path.read_text(encoding='utf-8')
        path.write_text(text.replace('## One runtime model', '## Runtime'), encoding='utf-8')
        self.assertIn('README.md: expected exactly one One runtime model section',
                      checker.check(self.root))

    def test_current_docs_pass(self):
        self.assertEqual(checker.check(self.root), [])

    def test_missing_translation_fails(self):
        (self.root / 'README.es.md').unlink()
        self.assertTrue(any('missing current translation' in e for e in checker.check(self.root)))

    def test_code_drift_fails(self):
        self.mutate('case settings', 'case preferences')
        self.assertTrue(any('Swift snippets differ' in e for e in checker.check(self.root)))

    def test_stale_version_fails(self):
        self.mutate('from: "7.0.0"', 'from: "6.1.0"')
        self.assertTrue(any('missing contract from:' in e for e in checker.check(self.root)))

    def test_contract_omission_fails(self):
        self.mutate('RouterPendingLinkPersistenceDriver', 'PendingLinkPersistenceDriver')
        self.assertTrue(any('missing contract RouterPendingLinkPersistenceDriver' in e for e in checker.check(self.root)))

    def test_broken_relative_link_fails(self):
        self.mutate('](Examples/MacrosExample.swift)', '](Examples/missing.swift)')
        self.assertTrue(any('broken local link' in e for e in checker.check(self.root)))

    def test_section_omission_fails(self):
        self.mutate('## Requisitos e instalación', 'Requisitos e instalación')
        self.assertTrue(any('expected 13 aligned sections' in e for e in checker.check(self.root)))


if __name__ == '__main__':
    unittest.main()
