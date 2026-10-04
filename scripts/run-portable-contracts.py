#!/usr/bin/env python3
"""Run narrow production Core/DeepLink contracts on a non-Apple executor.

This is not a package, SwiftUI, OSLog, native-platform, or release gate.
Copies are byte-identical except the explicit unavailable-platform #error
replacement below. OSLog is a test-only no-op shim. Record every substitution.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--source-revision')
parser.add_argument('--test-revision', help='Read test sources from this commit instead of the working tree')
parser.add_argument('--filter')
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--jobs', type=int, default=1)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = args.scratch.resolve()
if scratch == repo or repo in scratch.parents and '.build' not in scratch.parts:
    raise SystemExit('Use an external scratch directory or a path below .build')
scratch.mkdir(parents=True, exist_ok=True)
revision = args.source_revision or subprocess.check_output(
    ['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
manifest = {'source_revision': revision, 'scope': 'portable Core/DeepLink contracts only',
            'excluded': ['SwiftUI', 'OSLog effects', 'native platforms', 'full package', 'release'],
            'files': [], 'substitutions': []}
for module in ['InnoRouterCore', 'InnoRouterDeepLink']:
    directory = scratch / 'Sources' / module
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob('*.swift'):
        old.unlink()
    if args.source_revision:
        paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', revision,
                                         '--', f'Sources/{module}'], cwd=repo, text=True).splitlines()
    else:
        paths = [str(p.relative_to(repo)) for p in (repo / 'Sources' / module).glob('*.swift')]
    for relative in paths:
        if not relative.endswith('.swift'):
            continue
        data = (subprocess.check_output(['git', 'show', f'{revision}:{relative}'], cwd=repo)
                if args.source_revision else (repo / relative).read_bytes())
        original_hash = hashlib.sha256(data).hexdigest()
        marker = b'#error("InnoRouter supports only declared Apple platforms")'
        replacement = b'preconditionFailure("Apple capabilities are unavailable in portable contract tests")'
        if relative.endswith('/RouterPlatform.swift'):
            if data.count(marker) != 1:
                raise SystemExit('Expected exactly one explicit Apple-only compilation guard')
            data = data.replace(marker, replacement)
            manifest['substitutions'].append({'file': relative, 'from': marker.decode(),
                                               'to': replacement.decode(),
                                               'reason': 'No native capabilities are simulated'})
        (directory / Path(relative).name).write_bytes(data)
        manifest['files'].append({'path': relative, 'original_sha256': original_hash,
                                  'compiled_sha256': hashlib.sha256(data).hexdigest()})
shim = scratch / 'Sources' / 'OSLog'
shim.mkdir(parents=True, exist_ok=True)
(shim / 'Logger.swift').write_text('''
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func warning(_ message: Message) {}
    public func error(_ message: Message) {}
    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
        public init(stringLiteral value: String) {}
        public init(stringInterpolation: StringInterpolation) {}
        public struct StringInterpolation: StringInterpolationProtocol, Sendable {
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ literal: String) {}
            public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy) {}
        }
    }
    public enum Privacy: Sendable { case `public` }
}
''')
tests = scratch / 'Tests' / 'PortableContracts'
tests.mkdir(parents=True, exist_ok=True)
for old in tests.glob('*.swift'):
    old.unlink()
selected_tests = {
    'RouterLinkTargetPreservationTests.swift', 'RouterStateTests.swift',
    'RouterSnapshotTests.swift', 'RouterStateMachineTests.swift',
}
if args.test_revision:
    test_paths = subprocess.check_output([
        'git', 'ls-tree', '-r', '--name-only', args.test_revision,
        '--', 'Tests/InnoRouterTests',
    ], cwd=repo, text=True).splitlines()
else:
    test_paths = [str(p.relative_to(repo)) for p in (repo / 'Tests' / 'InnoRouterTests').glob('*.swift')]
for relative in sorted(test_paths):
    name = Path(relative).name
    if name not in selected_tests and not name.endswith('PortableContractTests.swift'):
        continue
    data = (subprocess.check_output(['git', 'show', f'{args.test_revision}:{relative}'], cwd=repo)
            if args.test_revision else (repo / relative).read_bytes())
    (tests / name).write_bytes(data)
manifest['test_revision'] = args.test_revision or 'working tree'

(scratch / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "InnoRouterPortableContracts", targets: [
    .target(name: "OSLog"),
    .target(name: "InnoRouterCore"),
    .target(name: "InnoRouterDeepLink", dependencies: ["InnoRouterCore", "OSLog"]),
    .testTarget(name: "PortableContracts", dependencies: ["InnoRouterCore", "InnoRouterDeepLink"])
])
''')
manifest['toolchain'] = subprocess.check_output(['swift', '--version'], text=True).strip()
manifest['test_sources'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in tests.glob('*.swift')}
command = ['swift', 'test', '--package-path', str(scratch), '--jobs', str(args.jobs), '--no-parallel', '--configuration', args.configuration]
if args.filter:
    command += ['--filter', args.filter]
command += ['--cache-path', str(scratch / 'cache'), '--config-path', str(scratch / 'configuration'), '--security-path', str(scratch / 'security')]
for name in ['CLANG_MODULE_CACHE_PATH', 'SWIFT_MODULECACHE_PATH', 'SWIFTPM_MODULECACHE_OVERRIDE']:
    os.environ[name] = str(scratch / 'module-cache')
manifest['command'] = command
(scratch / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
with (scratch / 'test.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
manifest['exit_code'] = result.returncode
(scratch / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
print((scratch / 'test.log').read_text())
raise SystemExit(result.returncode)
