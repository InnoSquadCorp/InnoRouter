#!/usr/bin/env python3
"""Execute the canonical Foundation/Observation Store engine on Linux.

No replacement Store, SwiftUI types, or native callbacks are simulated. Runtime
sources and tests are byte-identical to product paths. RouterNativeTransaction
selects its explicit non-UI assignment branch. The only staged substitutions
are the unused Core current-platform guard, a no-op OSLog module, and a reduced
actual umbrella export file excluding native System and Macros. This gate
does not validate native animation, rendering, callbacks, or the full package.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--filter')
parser.add_argument('--jobs', type=int, default=1)
parser.add_argument('--only-test-file', action='append', default=[], help='Use only these exact test files, replacing defaults')
parser.add_argument('--runtime-source-revision', help='Stage exact runtime files from this revision for an engine regression control')
parser.add_argument('--test-file', action='append', default=[], help='Add an exact Tests/InnoRouterTests file (repeatable)')
parser.add_argument('--policy-source-revision', help='Regression control only: use this exact prior RouterStore+Policy.swift')
parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
parser.add_argument('--warnings-as-errors', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
scratch = args.scratch.resolve()
if scratch == repo or (repo in scratch.parents and '.build' not in scratch.parts):
    raise SystemExit('Use an external scratch directory or a path below .build')
scratch.mkdir(parents=True, exist_ok=True)
# Preserve each attempt, including failures, before restaging source files.
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
    'scope': 'canonical Store/Foundation/Observation runtime contracts only',
    'runner_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
    'working_tree_status': subprocess.check_output(['git', 'status', '--short'], cwd=repo, text=True),
    'excluded': ['SwiftUI rendering', 'native animation and callbacks', 'OSLog emission', 'Apple platform capabilities', 'full package', 'release'],
    'files': [], 'substitutions': [],
    'policy_source_revision': args.policy_source_revision,
    'runtime_source_revision': args.runtime_source_revision,
    'native_test_exclusions': ['RouterStoreTests native Binding test block guarded by canImport(SwiftUI)'],
}


def stage(source, destination):
    if args.runtime_source_revision and source.parent.name == 'InnoRouterSwiftUI':
        data = subprocess.check_output(['git', 'show', f"{args.runtime_source_revision}:{source.relative_to(repo)}"], cwd=repo)
    else:
        data = source.read_bytes()
    if args.policy_source_revision and source.name == 'RouterStore+Policy.swift':
        data = subprocess.check_output(['git', 'show', f"{args.policy_source_revision}:{source.relative_to(repo)}"], cwd=repo)
    original_hash = hashlib.sha256(data).hexdigest()
    relative = str(source.relative_to(repo))
    if source.name == 'RouterPlatform.swift':
        marker = b'#error("InnoRouter supports only declared Apple platforms")'
        replacement = b'preconditionFailure("Apple capabilities are unavailable in Store engine contract tests")'
        if data.count(marker) != 1:
            raise SystemExit('Expected exactly one explicit Apple-only compilation guard')
        data = data.replace(marker, replacement)
        manifest['substitutions'].append({
            'file': relative, 'from': marker.decode(), 'to': replacement.decode(),
            'reason': 'Store engine contracts never request native platform capabilities',
        })
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    manifest['files'].append({
        'path': relative,
        'original_sha256': original_hash,
        'compiled_sha256': hashlib.sha256(data).hexdigest(),
    })


modules = ['InnoRouterCore', 'InnoRouterDeepLink', 'InnoRouterSwiftUI', 'InnoRouterSystem']
system_sources = {'RouterObservability.swift', 'RouterSignpostTracker.swift'}
for module in modules:
    directory = scratch / 'Sources' / module
    directory.mkdir(parents=True, exist_ok=True)
    for old in directory.glob('*.swift'):
        old.unlink()
    if module == 'InnoRouterSwiftUI' and args.runtime_source_revision:
        paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', args.runtime_source_revision, '--', f'Sources/{module}'], cwd=repo, text=True).splitlines()
        sources = [repo / path for path in paths if path.endswith('.swift')]
    else:
        sources = sorted((repo / 'Sources' / module).glob('*.swift'))
    for source in sources:
        if module == 'InnoRouterSystem' and source.name not in system_sources:
            continue
        if module == 'InnoRouterSwiftUI':
            if source.name == 'RouterTabRestorationTopology+Catalog.swift':
                continue
            contents = (subprocess.check_output(['git', 'show', f"{args.runtime_source_revision}:{source.relative_to(repo)}"], cwd=repo, text=True) if args.runtime_source_revision else source.read_text())
            if 'import SwiftUI' in contents and source.name != 'RouterNativeTransaction.swift':
                continue
        stage(source, directory / source.name)
shim = scratch / 'Sources/OSLog'
shim.mkdir(parents=True, exist_ok=True)
(shim / 'Logger.swift').write_text("""
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
""")
manifest['substitutions'].append({
    'file': 'Sources/OSLog/Logger.swift', 'reason': 'Linux logging-only shim; no runtime or UI behavior',
    'compiled_sha256': hashlib.sha256((shim / 'Logger.swift').read_bytes()).hexdigest(),
})
# Compile the actual umbrella export source with explicitly excluded native and
# macro exports. This checks reader contracts, not the complete public product.
umbrella_source = repo / 'Sources/InnoRouterUmbrella/InnoRouter.swift'
umbrella_data = umbrella_source.read_bytes()
umbrella_original = hashlib.sha256(umbrella_data).hexdigest()
for excluded_module in ['InnoRouterMacros']:
    marker = ('@_exported import ' + excluded_module + '\n').encode()
    if umbrella_data.count(marker) != 1:
        raise SystemExit('Umbrella adapter export boundary changed')
    umbrella_data = umbrella_data.replace(marker, b'')
umbrella = scratch / 'Sources/InnoRouter/InnoRouter.swift'
umbrella.parent.mkdir(parents=True, exist_ok=True)
umbrella.write_bytes(umbrella_data)
manifest['files'].append({'path': str(umbrella_source.relative_to(repo)),
    'original_sha256': umbrella_original,
    'compiled_sha256': hashlib.sha256(umbrella_data).hexdigest()})
manifest['substitutions'].append({'file': str(umbrella_source.relative_to(repo)),
    'reason': 'Exclude Macros from the actual umbrella; System target contains only pure diagnostics/tracker, with native factories excluded; full product unverified'})
tests = scratch / 'Tests/StoreEngineContracts'
tests.mkdir(parents=True, exist_ok=True)
for old in tests.glob('*.swift'):
    old.unlink()
selected_tests = [
    'RouterPolicyOperationBudgetTests.swift',
    'RouterRestorationOperationBudgetContractTests.swift',
    'RouterRestorationOperationBudgetTests.swift',
    'RouterPolicyOperationDefaultBoundRegressionTests.swift',
    'ManualRuntimeDependencies.swift',
    'RouterRuntimeDependencyTests.swift',
    'RouterFeatureMappingTests.swift',
    'RouterHistoryTests.swift',
    'RouterPlanLinkAdmissionTests.swift',
    'RouterLinkPipelineTests.swift',
    'RouterStoreTests.swift',
    'RouterTestEventWaiting.swift',
    'RouterPartialRestorationTests.swift',
    'RouterRestorationBoundaryRegressionTests.swift',
    'RouterRestorationStorageCancellationTests.swift',
    'RouterSnapshotLimitTests.swift',
    'RouterTabRestorationTopologyTests.swift',
    'RouterTwelfthReviewRegressionTests.swift',
    'RouterPartialRestorationPlannerContractTests.swift',
    'RouterTabRestorationTopologyContractTests.swift',
    'RouterFileStorageContractTests.swift',
    'RouterDurabilityStorageContractTests.swift',
    'RouterAuthorizationContractTests.swift',
    'RouterLinkTargetPreservationTests.swift',
    'RouterSignpostTrackerTests.swift',
    'RouterObservabilityTests.swift',
    'RouterPlatformCapabilitiesTests.swift',
    'TestTags.swift',
    'RouterEighteenthReviewRegressionTests.swift',
    'RouterNineteenthReviewRegressionTests.swift',
    'RouterStateRestorationTests.swift',
    'RouterTwentyFourthReviewRestorationTests.swift',
    'RouterTwentySecondReviewRegressionTests.swift',
    'RouterRestorationDriverPartialTests.swift',
    'RouterTwentyThirdReviewRestorationTests.swift',
    'RouterScopeLifetimeRegressionTests.swift',
    'RouterPresentationTerminalOwnershipTests.swift',
    'RouterPresentationIncarnationContractTests.swift',
    'RouterPresentationCompletionContextTests.swift',
    'RouterTransientPresentationLifetimeTests.swift',
    'RouterPresentationResultAuthorizationTests.swift',
    'RouterTransientFeatureContractTests.swift',
    'RouterPendingPresentationAuthorityTests.swift',
    'RouterPresentationHandleObservationTests.swift',
    'RouterNativePresentationAttemptTests.swift',
    'RouterActionsTransientContractTests.swift',
    'RouterEnclosingPresentationEndpointTests.swift',
    'RouterPresentationEnvironmentRebaseTests.swift',
    'RouterTransientConcurrencyContractTests.swift',

    'RouterTransientPendingPersistenceContractTests.swift',
    'RouterTransientHistoryContractTests.swift',
    'RouterScopeLifetimeContractTests.swift',
    'RouterScopeResourceAdmissionTests.swift',
    'EnvironmentRouterStateTests.swift',
    'RouterScopeProjectionReentrancyTests.swift',
    'RouterScopeSceneMetadataReentrancyTests.swift',
    'RouterDiagnosticFutureCodeTests.swift',
    'RouterPartialRestoreLifetimeRecoveryTests.swift', 'RouterGraphPersistenceContractTests.swift', 'RouterPendingLinkGraphPersistenceTests.swift', 'RouterStoreInitializationContractTests.swift', 'RouterPersistenceOwnerBudgetTests.swift', 'RouterAdmissionAuditRegressionTests.swift',
]
if args.only_test_file:
    selected_tests = []
for name in args.test_file + args.only_test_file:
    if Path(name).name != name or not name.endswith('.swift'):
        raise SystemExit('--test-file must name one Swift test file without path components')
    if name not in selected_tests:
        selected_tests.append(name)
for name in selected_tests:
    stage(repo / 'Tests/InnoRouterTests' / name, tests / name)
(scratch / 'Package.swift').write_text("""// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "InnoRouterStoreEngineContracts", targets: [
    .target(name: "OSLog"),
    .target(name: "InnoRouterCore"),
    .target(name: "InnoRouterDeepLink", dependencies: ["InnoRouterCore", "OSLog"]),
    .target(name: "InnoRouterSwiftUI", dependencies: ["InnoRouterCore", "InnoRouterDeepLink", "OSLog"]),
    .target(name: "InnoRouterSystem", dependencies: ["InnoRouterCore", "InnoRouterSwiftUI"]),
    .target(name: "InnoRouter", dependencies: ["InnoRouterCore", "InnoRouterDeepLink", "InnoRouterSwiftUI", "InnoRouterSystem"]),
    .testTarget(name: "StoreEngineContracts", dependencies: ["InnoRouterCore", "InnoRouterDeepLink", "InnoRouterSwiftUI", "InnoRouterSystem", "InnoRouter"])
])
""")
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
    if not (args.policy_source_revision and entry['path'].endswith('/RouterStore+Policy.swift'))
    and not (args.runtime_source_revision and entry['path'].startswith('Sources/InnoRouterSwiftUI/'))
)
(scratch / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(log_text)
if not manifest['staged_sources_still_match']:
    print('WARNING: Working tree changed after staging; results apply to recorded hashes only.')
raise SystemExit(manifest['exit_code'])
