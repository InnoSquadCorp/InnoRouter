"""Exercise the real shell orchestration with synthetic tool/executable fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NAMES = [
    'reducer_transition_throughput', 'snapshot_roundtrip_throughput',
    'deep_link_match_throughput', 'inspector_record_export_throughput',
    'scenario_capture_off_on_throughput', 'history_capacity_scaling', 'catalog_size_scaling',
]


class PerformanceDiagnosticsTests(unittest.TestCase):
    def run_fixture(self, canonical_failure=False, diagnostic_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            scripts.mkdir()
            binary = root / 'bin'
            binary.mkdir()
            for name in ['performance-smoke.sh', 'validate-performance-report.py']:
                shutil.copy2(ROOT / 'scripts' / name, scripts / name)
            for name in ['verify-json-key-fast-path.sh', 'test-validate-performance-report.sh']:
                (scripts / name).write_text('#!/bin/bash\nexit 0\n', encoding='utf-8')
            tools = {
                'xcrun': '#!/bin/bash\nprintf "%s\\n" "$FAKE_ROOT/SDK"\n',
                'swift': '#!/bin/bash\nif [[ "$*" == *--show-bin-path* ]]; then printf "%s\\n" "$FAKE_ROOT/bin"; fi\n',
                'InnoRouterPerformanceSmoke': '''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1] == '--self-test':
    sys.exit(0)
if sys.argv[1] == '--profile-json-keys':
    assert pathlib.Path(os.environ['REPORT_PATH']).is_file()
    pathlib.Path(os.environ['FAKE_ROOT'], 'profile-ran').write_text('yes')
    sys.exit(int(os.environ['PROFILE_EXIT']))
assert sys.argv[1] == '--output'
failed = os.environ['CANONICAL_FAIL'] == '1'
report = {'schemaVersion': 1, 'generatedAt': '2026-10-11T00:00:00Z',
          'configuration': 'release', 'aggregation': 'median', 'measurementCount': 5,
          'passed': not failed, 'samples': [
              {'name': name, 'iterations': 100, 'medianMilliseconds': 3.0 if failed else 1.0,
               'maximumMilliseconds': 2.0, 'operationsPerSecond': 100000 / (3 if failed else 1),
               'passed': not failed} for name in json.loads(os.environ['SAMPLE_NAMES'])]}
pathlib.Path(sys.argv[2]).write_text(json.dumps(report))
sys.exit(5 if failed else 0)
''',
            }
            for name, contents in tools.items():
                path = binary / name
                path.write_text(contents, encoding='utf-8')
                path.chmod(0o755)
            report = root / 'report.json'
            env = dict(os.environ, PATH=f'{binary}:{os.environ["PATH"]}', FAKE_ROOT=str(root),
                       REPORT_PATH=str(report), SAMPLE_NAMES=json.dumps(NAMES),
                       CANONICAL_FAIL=str(int(canonical_failure)), PROFILE_EXIT='91' if diagnostic_failure else '0')
            result = subprocess.run(['bash', str(scripts / 'performance-smoke.sh'), str(report)],
                                    env=env, text=True, capture_output=True)
            return result, json.loads(report.read_text(encoding='utf-8')), (root / 'profile-ran').exists()

    def test_diagnostic_failure_keeps_successful_canonical_report_and_exit(self):
        result, report, ran = self.run_fixture(diagnostic_failure=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(report['passed'])
        self.assertTrue(ran)
        self.assertIn('optional JSON-key attribution failed', result.stderr)

    def test_diagnostic_success_runs_only_after_report_exists(self):
        result, report, ran = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(report['passed'])
        self.assertTrue(ran)

    def test_canonical_failure_still_fails_and_does_not_run_diagnostics(self):
        result, report, ran = self.run_fixture(canonical_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(report['passed'])
        self.assertFalse(ran)
        self.assertIn('Failed thresholds', result.stderr)

    def test_profile_dispatch_is_separate_from_output(self):
        source = (ROOT / 'Sources/InnoRouterPerformanceSmoke/InnoRouterPerformanceSmoke.swift').read_text(encoding='utf-8')
        before, after = source.split('guard arguments.count == 2,', 1)
        self.assertIn('if arguments == ["--profile-json-keys"]', before)
        self.assertIn('try profileJSONKeyDecoding()', before)
        self.assertNotIn('try profileJSONKeyDecoding()', after)


if __name__ == '__main__':
    unittest.main()
