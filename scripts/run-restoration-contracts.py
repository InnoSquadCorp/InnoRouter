#!/usr/bin/env python3
"""Execute actual Foundation/Core partial-restoration planner sources on Linux.

No Store, SwiftUI, catalog, authentication, or policy adapters are simulated.
This narrow gate covers pure planning/topology and actual timeout races only.
Every compiled source hash and explicit substitution is retained in provenance.
Test sources are byte-identical to root tests; mutations affect staged copies.
"""
import argparse
import hashlib
import json
import os
import platform
import re
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--filter')
parser.add_argument('--jobs', type=int, default=1)
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--warnings-as-errors', action='store_true')
parser.add_argument('--mutation', choices=['skip-presentation-children', 'extend-replacement-bound', 'drop-orphans'])
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = args.scratch.resolve()
if scratch == repo or (repo in scratch.parents and '.build' not in scratch.parts):
    raise SystemExit('Use an external scratch directory or a path below .build')
scratch.mkdir(parents=True, exist_ok=True)
manifest = {
    'scope': 'production Foundation/Core partial-restoration planning and topology only',
    'platform': platform.platform(),
    'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'working_tree_status': subprocess.check_output(['git', 'status', '--short'], cwd=repo, text=True),
    'excluded': ['Store.apply and revision/policy/authorization integration', 'catalog adapters',
                 'native presentation lifetime/waiters', 'SwiftUI', 'validator admission/resource bounds',
                 'full package', 'minimum Swift toolchain', 'release'],
    'mutation': args.mutation,
    'files': [], 'substitutions': [],
}


def stage(source, destination):
    data = source.read_bytes()
    original_hash = hashlib.sha256(data).hexdigest()
    relative = str(source.relative_to(repo))
    if source.name == 'RouterPlatform.swift':
        marker = b'#error("InnoRouter supports only declared Apple platforms")'
        replacement = b'preconditionFailure("Apple capabilities are unavailable in restoration contract tests")'
        if data.count(marker) != 1:
            raise SystemExit('Expected exactly one explicit Apple-only compilation guard')
        data = data.replace(marker, replacement)
        manifest['substitutions'].append({
            'file': relative, 'from': marker.decode(), 'to': replacement.decode(),
            'reason': 'Planner and topology contracts never request native platform capabilities',
        })
    mutations = {
        'skip-presentation-children': ('RouterPartialRestoration.swift',
            b'        if var retained = presentation {\n            retained.node = try await node(\n                retained.node,\n                at: scope.appendingPresentation(retained.id),\n                report: &report\n            )\n            presentation = retained\n        }',
            b'        // Mutation: intentionally skip retained presentation descendants.'),
        'extend-replacement-bound': ('RouterPartialRestoration.swift',
            b'private static var maximumReplacementCount: Int { 8 }',
            b'private static var maximumReplacementCount: Int { 9 }'),
        'drop-orphans': ('RouterTabRestorationTopology.swift',
            b'branches: current + orphans,', b'branches: current + Array(orphans.prefix(0)),')
    }
    if args.mutation:
        filename, before, after = mutations[args.mutation]
        if source.name == filename:
            if data.count(before) != 1:
                raise SystemExit('Mutation anchor must match exactly once')
            data = data.replace(before, after)
            manifest['substitutions'].append({
                'file': relative, 'from': before.decode(), 'to': after.decode(),
                'reason': 'Intentional negative control: ' + args.mutation,
            })
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    manifest['files'].append({
        'path': relative,
        'original_sha256': original_hash,
        'compiled_sha256': hashlib.sha256(data).hexdigest(),
    })


core = scratch / 'Sources/InnoRouterCore'
planner = scratch / 'Sources/InnoRouterRestorationContracts'
tests = scratch / 'Tests/RestorationContracts'
for directory in [core, planner, tests]:
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob('*.swift'):
        old.unlink()
for source in sorted((repo / 'Sources/InnoRouterCore').glob('*.swift')):
    stage(source, core / source.name)
for name in ['RouterPartialRestoration.swift', 'RouterTabRestorationTopology.swift']:
    stage(repo / 'Sources/InnoRouterSwiftUI' / name, planner / name)
for name in ['RouterPartialRestorationPlannerContractTests.swift', 'RouterTabRestorationTopologyContractTests.swift']:
    source = repo / 'Tests/InnoRouterTests' / name
    stage(source, tests / source.name)
if not list(tests.glob('*.swift')):
    raise SystemExit('No restoration contract test sources found')
(scratch / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "InnoRouterRestorationPlannerContracts", targets: [
    .target(name: "InnoRouterCore"),
    .target(name: "InnoRouterRestorationContracts", dependencies: ["InnoRouterCore"]),
    .testTarget(name: "RestorationContracts", dependencies: ["InnoRouterCore", "InnoRouterRestorationContracts"])
])
''')
manifest['toolchain'] = subprocess.check_output(['swift', '--version'], text=True).strip()
command = ['swift', 'test', '--package-path', str(scratch), '--jobs', str(args.jobs), '--no-parallel',
           '--configuration', args.configuration]
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
summary = re.search(r'Test run with (\d+) tests? in (\d+) suites? (passed|failed)', log_text)
manifest['test_summary'] = summary.group(0) if summary else None
manifest['test_function_count'] = int(summary.group(1)) if summary else 0
manifest['exit_code'] = result.returncode
if result.returncode == 0 and not manifest['test_function_count']:
    manifest['exit_code'] = 1
    manifest['failure_reason'] = 'The Swift Testing log did not confirm any executed tests'
manifest['staged_sources_still_match'] = all(
    hashlib.sha256((repo / entry['path']).read_bytes()).hexdigest() == entry['original_sha256']
    for entry in manifest['files']
)
(scratch / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(log_text)
if not manifest['staged_sources_still_match']:
    print('WARNING: Working tree changed after staging; results apply to recorded hashes only.')
raise SystemExit(manifest['exit_code'])
