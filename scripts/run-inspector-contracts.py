#!/usr/bin/env python3
"""Run actual non-UI Inspector sources and contracts on Linux.

No SwiftUI or RouterStore stand-ins are compiled. Exact production source,
resources and test hashes are recorded; the only staged source substitution is
Core's explicit Apple-only platform guard. Native Inspector views and Store
attachment remain separate Apple-platform gates.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--filter')
parser.add_argument('--jobs', type=int, default=1)
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--warnings-as-errors', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = args.scratch.resolve()
if scratch == repo or (repo in scratch.parents and '.build' not in scratch.parts):
    raise SystemExit('Use an external scratch directory or a path below .build')
scratch.mkdir(parents=True, exist_ok=True)
if (scratch / 'provenance.json').exists() or (scratch / 'test.log').exists():
    archive = scratch / 'runs' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    archive.mkdir(parents=True)
    for name in ['provenance.json', 'test.log', 'Package.swift']:
        if (scratch / name).exists():
            shutil.copy2(scratch / name, archive / name)
    for name in ['Sources', 'Tests']:
        if (scratch / name).exists():
            shutil.copytree(scratch / name, archive / name)
manifest = {
    'scope': 'production non-UI Inspector contracts only',
    'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'working_tree_status': subprocess.check_output(['git', 'status', '--short'], cwd=repo, text=True),
    'excluded': ['SwiftUI views', 'RouterStore attachment', 'native platform behavior', 'full package', 'release gate'],
    'files': [], 'substitutions': [],
}


def stage(source, destination):
    data = source.read_bytes()
    original_hash = hashlib.sha256(data).hexdigest()
    relative = str(source.relative_to(repo))
    if source.name == 'RouterPlatform.swift':
        marker = b'#error("InnoRouter supports only declared Apple platforms")'
        replacement = b'preconditionFailure("Apple capabilities are unavailable in Inspector contract tests")'
        if data.count(marker) != 1:
            raise SystemExit('Expected exactly one explicit Apple-only compilation guard')
        data = data.replace(marker, replacement)
        manifest['substitutions'].append({
            'file': relative, 'from': marker.decode(), 'to': replacement.decode(),
            'reason': 'Inspector contracts supply platform metadata explicitly and never request native capabilities',
        })
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    manifest['files'].append({
        'path': relative, 'original_sha256': original_hash,
        'compiled_sha256': hashlib.sha256(data).hexdigest(),
    })


core = scratch / 'Sources/InnoRouterCore'
inspector = scratch / 'Sources/InnoRouterInspector'
tests = scratch / 'Tests/InspectorContracts'
for directory in [core, inspector, tests]:
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob('*.swift'):
        old.unlink()
for source in sorted((repo / 'Sources/InnoRouterCore').glob('*.swift')):
    stage(source, core / source.name)
for name in ['RouterInspectorModels.swift', 'RouterInspectorSourceCatalog.swift',
             'RouterInspectorImportPreflight.swift', 'RouterInspectorRecorder.swift',
             'RouterInspectorExportFailure.swift',
             'RouterInspectorRedaction.swift', 'RouterInspectorState.swift',
             'RouterInspectorTimeline.swift', 'RouterInspectorScenarioController.swift',
             'Localizable.xcstrings']:
    stage(repo / 'Sources/InnoRouterInspector' / name, inspector / name)
for source in sorted((repo / 'Tests/InnoRouterInspectorTests').glob('*.swift')):
    if source.name in ['RouterInspectorTests.swift', 'RouterLifecycleTests.swift']:
        continue  # Existing integration suite depends on actual SwiftUI Store.
    stage(source, tests / source.name)
if not list(tests.glob('*.swift')):
    raise SystemExit('No Inspector contract test sources found')
expected_count = sum(
    len(re.findall(r'^[ \t]*@Test\b', source.read_text(), re.M))
    for source in tests.glob('*.swift')
)
manifest['expected_unfiltered_test_function_count'] = expected_count
if not expected_count:
    raise SystemExit('No Inspector contract test functions found')
(scratch / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "InnoRouterInspectorContracts", defaultLocalization: "en", targets: [
    .target(name: "InnoRouterCore"),
    .target(name: "InnoRouterInspector", dependencies: ["InnoRouterCore"],
            resources: [.copy("Localizable.xcstrings")]),
    .testTarget(name: "InspectorContracts", dependencies: ["InnoRouterCore", "InnoRouterInspector"])
])
''')
manifest['toolchain'] = subprocess.check_output(['swift', '--version'], text=True).strip()
command = ['swift', 'test', '--package-path', str(scratch), '--jobs', str(args.jobs), '--no-parallel',
           '--configuration', args.configuration, '-Xswiftc', '-strict-concurrency=complete']
if args.warnings_as_errors:
    command += ['-Xswiftc', '-warnings-as-errors']
if args.filter:
    command += ['--filter', args.filter]
command += ['--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'configuration'),
            '--security-path', str(scratch / 'security')]
for name in ['CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULECACHE_PATH', 'SWIFTPM_MODULECACHE_OVERRIDE']:
    os.environ[name] = str(scratch / 'module-cache')
manifest['command'] = command
(scratch / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
with (scratch / 'test.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
log_text = (scratch / 'test.log').read_text()
summaries = list(re.finditer(
    r'Test run with (\d+) tests?(?: in (\d+) suites?)? (passed|failed)[^\r\n]*', log_text
))
summary = summaries[-1] if summaries else None
manifest['test_summary'] = summary.group(0) if summary else None
manifest['test_function_count'] = int(summary.group(1)) if summary else 0
manifest['test_suite_count'] = int(summary.group(2)) if summary and summary.group(2) else 0
manifest['swift_exit_code'] = result.returncode
manifest['exit_code'] = result.returncode
if result.returncode == 0 and (
    not summary or not manifest['test_function_count'] or summary.group(3) != 'passed'
    or (not args.filter and manifest['test_function_count'] != expected_count)
):
    manifest['exit_code'] = 1
    manifest['failure_reason'] = 'Executed Swift Testing cohort does not match the requested contract sources'
manifest['staged_sources_still_match'] = all(
    hashlib.sha256((repo / entry['path']).read_bytes()).hexdigest() == entry['original_sha256']
    for entry in manifest['files']
)
(scratch / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(log_text)
if 'failure_reason' in manifest:
    print('ERROR: ' + manifest['failure_reason'])
if not manifest['staged_sources_still_match']:
    print('WARNING: Working tree changed after staging; results apply to recorded hashes only.')
raise SystemExit(manifest['exit_code'])
