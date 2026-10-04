#!/usr/bin/env python3
"""Execute actual Foundation-only persistence sources on a non-Apple executor.

No I/O implementations or SwiftUI types are simulated. This is a narrow storage
and ordering gate, not the SwiftUI driver, package, Apple filesystem, or release
gate. Every compiled source hash and the sole Core platform guard substitution
are retained in provenance.json. Test sources are byte-identical to root tests.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--filter')
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--jobs', type=int, default=1)
parser.add_argument('--warnings-as-errors', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = args.scratch.resolve()
if scratch == repo or (repo in scratch.parents and '.build' not in scratch.parts):
    raise SystemExit('Use an external scratch directory or a path below .build')
scratch.mkdir(parents=True, exist_ok=True)
manifest = {
    'scope': 'production Foundation storage and durability contracts only',
    'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'working_tree_status': subprocess.check_output(['git', 'status', '--short'], cwd=repo, text=True),
    'excluded': ['SwiftUI drivers', 'native platform behavior', 'Apple filesystem semantics', 'full package', 'release'],
    'files': [], 'substitutions': [],
}


def stage(source, destination):
    data = source.read_bytes()
    original_hash = hashlib.sha256(data).hexdigest()
    relative = str(source.relative_to(repo))
    if source.name == 'RouterPlatform.swift':
        marker = b'#error("InnoRouter supports only declared Apple platforms")'
        replacement = b'preconditionFailure("Apple capabilities are unavailable in storage contract tests")'
        if data.count(marker) != 1:
            raise SystemExit('Expected exactly one explicit Apple-only compilation guard')
        data = data.replace(marker, replacement)
        manifest['substitutions'].append({
            'file': relative, 'from': marker.decode(), 'to': replacement.decode(),
            'reason': 'Storage contracts never request native platform capabilities',
        })
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    manifest['files'].append({
        'path': relative,
        'original_sha256': original_hash,
        'compiled_sha256': hashlib.sha256(data).hexdigest(),
    })


core = scratch / 'Sources/InnoRouterCore'
persistence = scratch / 'Sources/InnoRouterPersistenceContracts'
tests = scratch / 'Tests/PersistenceContracts'
for directory in [core, persistence, tests]:
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob('*.swift'):
        old.unlink()
for source in sorted((repo / 'Sources/InnoRouterCore').glob('*.swift')):
    stage(source, core / source.name)
for name in ['RouterSnapshotStorage.swift', 'RouterPendingLinkStorage.swift',
             'RouterByteStore.swift', 'RouterDurabilityGate.swift']:
    stage(repo / 'Sources/InnoRouterSwiftUI' / name, persistence / name)
for source in sorted((repo / 'Tests/InnoRouterTests').glob('*StorageContractTests.swift')):
    stage(source, tests / source.name)
if not list(tests.glob('*.swift')):
    raise SystemExit('No storage contract test sources found')
(scratch / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "InnoRouterStorageContracts", targets: [
    .target(name: "InnoRouterCore"),
    .target(name: "InnoRouterPersistenceContracts", dependencies: ["InnoRouterCore"]),
    .testTarget(name: "PersistenceContracts", dependencies: ["InnoRouterCore", "InnoRouterPersistenceContracts"])
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
