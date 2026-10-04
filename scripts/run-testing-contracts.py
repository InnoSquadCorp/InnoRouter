#!/usr/bin/env python3
"""Execute real Testing/Store/Inspector contracts on a non-Apple executor.

Production Testing sources and test fixtures are byte-identical. The reduced
InnoRouter export module intentionally omits Macros and System, and therefore
does not validate the shipped umbrella or package graph. No SwiftUI module,
Store, Inspector, or Testing implementation is substituted.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--jobs', type=int, default=1)
parser.add_argument('--filter')
parser.add_argument('--timeout', type=int, default=300, help='Whole build/test wall-clock limit in seconds')
parser.add_argument('--warnings-as-errors', action='store_true')
parser.add_argument('--fixture-decoder-body-revision', help='Regression control: borrow only the exact prior decode method body, retaining current API/schema declarations')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = args.scratch.resolve()
if scratch == repo or (repo in scratch.parents and '.build' not in scratch.parts):
    raise SystemExit('Use an external scratch directory or a path below .build')
if args.jobs < 1 or args.timeout < 1:
    raise SystemExit('--jobs and --timeout must be positive')
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
    'scope': 'actual Testing contracts with canonical non-UI Store and Inspector',
    'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'working_tree_status': subprocess.check_output(['git', 'status', '--short'], cwd=repo, text=True),
    'fixture_decoder_body_revision': args.fixture_decoder_body_revision,
    'excluded': ['SwiftUI rendering and native callbacks', 'OSLog emission',
                 'Apple platform capabilities', 'Macros/System umbrella exports',
                 'shipped product graph', 'Swift 6.3 floor', 'release gate'],
    'files': [], 'substitutions': [], 'excluded_sources': [],
    'expected_known_issues': ['RouterTestStoreTests intentionally exercises finish() diagnostics with withKnownIssue; this is a positive diagnostic assertion, not an accepted runtime failure'],
}


def stage(source, destination):
    data = source.read_bytes()
    original_hash = hashlib.sha256(data).hexdigest()
    relative = str(source.relative_to(repo))
    if args.fixture_decoder_body_revision and relative == 'Sources/InnoRouterTesting/RouterScenarioFixture.swift':
        prior = subprocess.check_output(['git', 'show', f'{args.fixture_decoder_body_revision}:{relative}'], cwd=repo)
        pattern = rb'(    public static func decode\([\s\S]*?\) throws -> Self \{)([\s\S]*?)(\n    \}\n\n    private enum CodingKeys)'
        old_method = re.search(pattern, prior)
        current_method = re.search(pattern, data)
        if old_method is None or current_method is None:
            raise SystemExit('Expected one recognizable Fixture.decode method body in both revisions')
        prior_body = old_method.group(2)
        data = data[:current_method.start(2)] + prior_body + data[current_method.end(2):]
        manifest['substitutions'].append({
            'file': relative, 'prior_revision': args.fixture_decoder_body_revision,
            'prior_file_sha256': hashlib.sha256(prior).hexdigest(),
            'prior_body_sha256': hashlib.sha256(prior_body).hexdigest(),
            'reason': 'Exact prior decoder body control; current signature/schema retained so new boundary tests compile. Not a full historical package baseline.',
        })
    if source.name == 'RouterPlatform.swift':
        marker = b'#error("InnoRouter supports only declared Apple platforms")'
        replacement = b'preconditionFailure("Apple capabilities are unavailable in Testing contract tests")'
        if data.count(marker) != 1:
            raise SystemExit('Expected exactly one explicit Apple-only compilation guard')
        data = data.replace(marker, replacement)
        manifest['substitutions'].append({
            'file': relative, 'from': marker.decode(), 'to': replacement.decode(),
            'reason': 'Contracts must never request native platform capabilities',
        })
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    manifest['files'].append({
        'path': relative, 'original_sha256': original_hash,
        'compiled_sha256': hashlib.sha256(data).hexdigest(),
    })


inspector_sources = {
    'RouterInspectorModels.swift', 'RouterInspectorSourceCatalog.swift',
    'RouterInspectorImportPreflight.swift', 'RouterInspectorRecorder.swift',
    'RouterInspectorRedaction.swift', 'RouterInspectorState.swift',
    'RouterInspectorTimeline.swift', 'RouterInspectorScenarioController.swift',
    'RouterInspectorStoreAdapter.swift', 'RouterInspectorExportFailure.swift', 'RouterInspectorResourceBudget.swift',
}
modules = ['InnoRouterCore', 'InnoRouterDeepLink', 'InnoRouterSwiftUI',
           'InnoRouterInspector', 'InnoRouterTesting']
for module in modules:
    directory = scratch / 'Sources' / module
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob('*.swift'):
        old.unlink()
    for source in sorted((repo / 'Sources' / module).glob('*.swift')):
        reason = None
        if module == 'InnoRouterSwiftUI':
            if source.name == 'RouterTabRestorationTopology+Catalog.swift':
                reason = 'Native route catalog adapter'
            elif 'import SwiftUI' in source.read_text() and source.name != 'RouterNativeTransaction.swift':
                reason = 'Native SwiftUI source'
        elif module == 'InnoRouterInspector' and source.name not in inspector_sources:
            reason = 'Native Inspector view'
        if reason:
            manifest['excluded_sources'].append({'path': str(source.relative_to(repo)), 'reason': reason})
            continue
        stage(source, directory / source.name)
stage(repo / 'Sources/InnoRouterInspector/Localizable.xcstrings',
      scratch / 'Sources/InnoRouterInspector/Localizable.xcstrings')

shim = scratch / 'Sources/OSLog'
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
umbrella = scratch / 'Sources/InnoRouter'
umbrella.mkdir(parents=True, exist_ok=True)
(umbrella / 'InnoRouter.swift').write_text('''// Test-only reduced export surface; not the shipped product.
@_exported import InnoRouterCore
@_exported import InnoRouterSwiftUI
@_exported import InnoRouterDeepLink
''')
for relative, reason in [
    ('Sources/OSLog/Logger.swift', 'Linux no-op logging shim; emission and privacy behavior excluded'),
    ('Sources/InnoRouter/InnoRouter.swift', 'Reduced exports omit InnoRouterMacros and InnoRouterSystem; not umbrella/package verification'),
]:
    manifest['substitutions'].append({
        'file': relative, 'reason': reason,
        'compiled_sha256': hashlib.sha256((scratch / relative).read_bytes()).hexdigest(),
    })

tests = scratch / 'Tests/InnoRouterTestingTests'
tests.mkdir(parents=True, exist_ok=True)
for old in tests.glob('*.swift'):
    old.unlink()
for source in sorted((repo / 'Tests/InnoRouterTestingTests').glob('*.swift')):
    stage(source, tests / source.name)
test_functions = []
for source in sorted(tests.glob('*.swift')):
    contents = source.read_text()
    for annotation in re.finditer(r'^[ \t]*@Test\b', contents, re.M):
        declaration = re.search(r'\bfunc\s+(`?\w+`?)\s*\(', contents[annotation.end():])
        if declaration is None:
            raise SystemExit(f'No test function declaration after {source.name}:{annotation.start()}')
        test_functions.append({
            'source': f'Tests/InnoRouterTestingTests/{source.name}',
            'annotation_line': contents.count('\n', 0, annotation.start()) + 1,
            'function': declaration.group(1),
        })
manifest['test_function_inventory'] = test_functions
expected_count = len(test_functions)
if not expected_count:
    raise SystemExit('No Testing contract functions found')
manifest['expected_unfiltered_test_function_count'] = expected_count

(scratch / 'Package.swift').write_text('''// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "InnoRouterTestingContracts", defaultLocalization: "en", targets: [
    .target(name: "OSLog"),
    .target(name: "InnoRouterCore"),
    .target(name: "InnoRouterDeepLink", dependencies: ["InnoRouterCore", "OSLog"]),
    .target(name: "InnoRouterSwiftUI", dependencies: ["InnoRouterCore", "InnoRouterDeepLink", "OSLog"]),
    .target(name: "InnoRouterInspector", dependencies: ["InnoRouterCore", "InnoRouterSwiftUI"],
            resources: [.copy("Localizable.xcstrings")]),
    .target(name: "InnoRouterTesting", dependencies: ["InnoRouterCore", "InnoRouterSwiftUI", "InnoRouterInspector"]),
    .target(name: "InnoRouter", dependencies: ["InnoRouterCore", "InnoRouterSwiftUI", "InnoRouterDeepLink"]),
    .testTarget(name: "InnoRouterTestingTests", dependencies: ["InnoRouter", "InnoRouterTesting", "InnoRouterInspector"])
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
manifest['timeout_seconds'] = args.timeout
with (scratch / 'test.log').open('w') as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        result_code = process.wait(timeout=args.timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        result_code = 124 if isinstance(error, subprocess.TimeoutExpired) else 130
        manifest['failure_reason'] = 'Build/test wall-clock timeout' if result_code == 124 else 'Interrupted execution'

log_text = (scratch / 'test.log').read_text()
summary = re.search(r'Test run with (\d+) tests? in (\d+) suites? (passed|failed)', log_text)
manifest['test_summary'] = summary.group(0) if summary else None
manifest['test_function_count'] = int(summary.group(1)) if summary else 0
manifest['exit_code'] = result_code
if result_code == 0 and (not manifest['test_function_count'] or
        (not args.filter and manifest['test_function_count'] != expected_count)):
    manifest['exit_code'] = 1
    manifest['failure_reason'] = 'Executed Swift Testing cohort does not match the requested contract sources'
manifest['staged_sources_still_match'] = all(
    hashlib.sha256((repo / entry['path']).read_bytes()).hexdigest() == entry['original_sha256']
    for entry in manifest['files']
)
(scratch / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(log_text)
if not manifest['staged_sources_still_match']:
    print('WARNING: Working tree changed after staging; results apply to recorded hashes only.')
raise SystemExit(manifest['exit_code'])
