#!/usr/bin/env python3
"""Typecheck external-module boundaries against an already built Linux engine.

This is not the shipped umbrella/product/API-baseline gate. No @testable import,
package identity, generated fake UI, or source-level access relaxation is used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--modules', required=True, type=Path)
parser.add_argument('--build-provenance', required=True, type=Path)
parser.add_argument('--scratch', required=True, type=Path)
parser.add_argument('--only-fixture', action='append', default=[], help='Run selected boundary probes against a reduced module set')
args = parser.parse_args()
args.scratch.mkdir(parents=True, exist_ok=True)
base = 'import Foundation\nimport InnoRouterCore\nenum R: String, Route { case home }\n'
state = base + 'var state = RouterState<R>.rootStack\n'
fixtures = {
    'draft_positive': (state + 'var draft = RouterStateDraft(state)\ndraft.root = .stack(path: [.home])\nlet next = try draft.build()\n', None),
    'graph_non_codable_positive': (base + '''let routes = try RouterGraphRouteCodec<R>(supportedPayloadVersions: ["home": 3]) { _ in
    RouterGraphRoutePayload(stableKey: "home", payloadVersion: 3, data: Data())
} decode: { _ in .home }
let codec = try RouterGraphSnapshotCodec(schemaID: "consumer", schemaVersion: 12, routes: routes)
let restored = try codec.decode(codec.encode(RouterState<R>.rootStack(path: [.home])))
''', None),
    'unknown_code_positive': (base + '''let failure = RouterAuthorizationFailure(code: .init(rawValue: "authorization.future"))
func classify(_ failure: RouterAuthorizationFailure) -> Bool {
    switch failure.code { case .denied: true; default: false }
}
let catalog = RouterAuthorizationCatalog<R>()
let config = RouterAuthorizationConfiguration<R>(generation: { 0 }, requiresAuthorization: { _ in true }, authorize: { true }, catalog: { catalog })
''', None),
    'root_setter_negative': (state + 'state.root = .stack()\n', r"'root'.*(?:inaccessible|immutable)|cannot assign.*'root'"),
    'windows_setter_negative': (state + 'state.windows = []\n', r"'windows'.*(?:inaccessible|immutable)|cannot assign.*'windows'"),
    'immersive_setter_negative': (state + 'state.immersiveSpace = nil\n', r"'immersiveSpace'.*(?:inaccessible|immutable)|cannot assign.*'immersiveSpace'"),
    'nested_setter_negative': (state + 'state.windows[0].node = .stack()\n', r"'windows'.*(?:inaccessible|immutable)|cannot assign.*'windows'"),
    'inout_setter_negative': (state + 'func mutate(_ value: inout RouterNode<R>) {}\nmutate(&state.root)\n', r"cannot pass immutable value as inout|setter is inaccessible"),
    'replay_limitation_negative': (base + 'func probe(_ value: RouterRequestObservation<R>) { _ = value.replayLimitationCode }\n', r"'replayLimitationCode'.*inaccessible|package.*protection"),
    'policy_bypass_negative': (base + 'import InnoRouterSwiftUI\n@MainActor func probe(_ store: RouterStore<R>) async { _ = await store.perform(.push(.home), context: .init(), expectedRevision: nil, bypassesPolicies: true) }\n', r"extra arguments|inaccessible|no exact matches"),
    'operation_registry_negative': (base + 'let registry = RouterOperationRegistry(maximumCount: 1)\n', r"cannot find 'RouterOperationRegistry'|package.*protection"),
    'store_setter_negative': (base + 'import InnoRouterSwiftUI\n@MainActor func probe(_ store: RouterStore<R>) { store.state = .rootStack }\n', r"'state'.*(?:inaccessible|immutable)|cannot assign.*'state'"),
    'scope_setter_negative': (base + 'import InnoRouterSwiftUI\n@MainActor func probe(_ scope: RouterScope<R>) { scope.node = .stack() }\n', r"'node'.*(?:inaccessible|immutable)|cannot assign.*'node'"),
}
runtime = base + 'import InnoRouterSwiftUI\n'
fixtures.update({
    'empty_store_nonthrowing_positive': (runtime + '@MainActor func empty() -> RouterStore<R> { RouterStore<R>() }\n', None),
    'input_store_throwing_positive': (runtime + '@MainActor func configured() throws { _ = try RouterStore<R>(initialPath: [.home]); _ = try RouterStore<R>(initialState: .rootStack); _ = try RouterStore<R>(configuration: .init(resourceBudget: .provisional)) }\n', None),
    'initial_path_requires_try_negative': (runtime + '@MainActor func unsafe() { _ = RouterStore<R>(initialPath: [.home]) }\n', r'call can throw.*not marked|errors thrown.*not handled'),
    'initial_state_requires_try_negative': (runtime + '@MainActor func unsafe() { _ = RouterStore<R>(initialState: .rootStack) }\n', r'call can throw.*not marked|errors thrown.*not handled'),
    'configuration_requires_try_negative': (runtime + '@MainActor func unsafe() { _ = RouterStore<R>(configuration: .init()) }\n', r'call can throw.*not marked|errors thrown.*not handled'),
    'store_budget_setter_negative': (runtime + '@MainActor func mutate(_ store: RouterStore<R>) { store.resourceBudget = .unlimited }\n', r"'resourceBudget'.*(?:constant|immutable|inaccessible)|cannot assign.*'resourceBudget'"),
    'owner_codec_adapter_negative': (base + 'func probe(_ codec: RouterGraphSnapshotCodec<R>) throws { _ = try codec.constrained(to: .provisional) }\n', r"'constrained'.*inaccessible|package.*protection"),
})
fixtures.update({
    'transient_sendable_value_positive': (runtime + """
struct Opaque: Sendable { let operation: @Sendable () -> Int }
@MainActor func probe(_ store: RouterStore<R>, _ scope: RouterScope<R>, _ actions: RouterActions<R>) async {
    let request = RouterTransientPresentationRequest<Opaque>.alert(title: "Title", actions: [
        .init(id: "choose", label: "Choose", role: .cancel, value: Opaque(operation: { 42 }))
    ])
    _ = await store.present(request)
    _ = await scope.present(request)
    _ = await actions.present(request)
    if let handle = store.presentationHandle() {
        _ = await store.selectPresentationAction("choose", using: handle)
        _ = await store.dismissPresentation(using: handle)
    }
}
""", None),
    'presentation_handle_constructor_negative': (runtime + 'let handle = RouterPresentationHandle(id: UUID(), scope: .root, token: UUID())\n', r"inaccessible|no accessible initializers|extra arguments"),
    'presentation_handle_codable_negative': (runtime + 'func persist(_ handle: RouterPresentationHandle) throws { _ = try JSONEncoder().encode(handle) }\n', r"requires.*conform.*Encodable|does not conform.*Encodable"),
    'presentation_resume_authority_negative': (runtime + 'let owner = RouterPresentationResumeAuthority()\n', r"cannot find|inaccessible|protection level"),
    'transient_transport_capability_negative': (base + 'let encoder = RouterTransientDescriptorTransport.encoder()\n', r"cannot find|inaccessible|protection level"),
})
fixtures.update({
    'host_descriptor_public_positive': (base + """
let shape = RouterHostShape.tabs(branches: [RouterHostBranch("home", shape: .stack)], extras: .preserveDormant)
let childCatalog = RouterHostCatalog<R>(entries: [RouterHostCatalogEntry("editor", shape: .stack)], declaration: { _ in "editor" })
let descriptor = RouterHostDescriptor<R>(root: .stack, presentations: childCatalog, windows: .stack, immersiveSpaces: .none)
try descriptor.validate(RouterState<R>.rootStack, resourceBudget: .provisional)
try descriptor.validate(RouterStateDraft<R>(), resourceBudget: .provisional)
try descriptor.validateRenderer(.stack, at: .root, in: RouterState<R>.rootStack, resourceBudget: .provisional)
let declared = try descriptor.shape(at: .root, in: RouterState<R>.rootStack)
let shapes: Set<RouterHostShape> = [shape, declared]
""", None),
    'host_failure_extensible_positive': (base + """
let failure = RouterHostValidationFailure(code: .init(rawValue: "hostShape.future"))
let required = RouterHostValidationFailure(code: .required, scope: .root)
let stale = RouterHostValidationFailure(code: .stale, scope: .root)
let rejection = RouterRejectionReason.hostContract(stale)
func classify(_ failure: RouterHostValidationFailure) -> Bool {
    switch failure.code { case .rendererMismatch: true; default: false }
}
let failures: Set<RouterHostValidationFailure> = [failure, required]
""", None),
    'host_prototype_alias_negative': (base + 'let shape = RouterHostShapeContract.stack\n', r"cannot find 'RouterHostShapeContract'|inaccessible|package.*protection"),
    'host_descriptor_mutation_negative': (base + 'var descriptor = RouterHostDescriptor<R>(root: .stack)\ndescriptor.root = .stack\n', r"'root'.*(?:constant|immutable|inaccessible)|cannot assign.*'root'"),
    'host_catalog_mutation_negative': (base + 'var catalog = RouterHostCatalog<R>.stack\ncatalog.entries.append(.init("new", shape: .stack))\n', r"'entries'.*(?:constant|immutable|inaccessible)|cannot use mutating member.*immutable"),
    'host_catalog_resolver_negative': (base + 'let catalog = RouterHostCatalog<R>.stack\n_ = catalog.declaration(.home)\n', r"'declaration'.*inaccessible|package.*protection"),
    'host_failure_detail_negative': (base + 'let failure = RouterHostValidationFailure(code: .required)\n_ = failure.detail\n', r"'detail'.*inaccessible|package.*protection"),
})
fixtures.update({
    'host_root_meaning_positive': (base + """
let roots: [RouterHostRootDeclaration<R>] = [.init(path: [], meaning: .route(.home))]
let descriptor = RouterHostDescriptor<R>(root: .stack, rootDeclarations: roots)
try descriptor.validateRenderer(.stack, rootDeclarations: roots, at: .root, in: .rootStack)
let entry = RouterHostCatalogEntry<R>("detail", shape: .stack, rootDeclarations: [.init(meaning: .declarationID("detail.root"))])
let catalog = RouterHostCatalog<R>(entries: [entry], declaration: { _ in "detail" })
""", None),
    'host_root_declarations_immutable_negative': (base + 'var descriptor = RouterHostDescriptor<R>(root: .stack)\ndescriptor.rootDeclarations = []\n', r"cannot assign.*'rootDeclarations'|immutable|let.constant"),
    'host_root_path_immutable_negative': (base + 'var root = RouterHostRootDeclaration<R>(meaning: .route(.home))\nroot.path = ["other"]\n', r"cannot assign.*'path'|immutable|let.constant"),
    'host_presentation_lookup_private_negative': (base + 'let descriptor = RouterHostDescriptor<R>(root: .stack)\n_ = try descriptor.presentationDeclaration(at: .root, in: .rootStack)\n', r"'presentationDeclaration'.*inaccessible|package.*protection"),
    'host_owner_replace_positive': (runtime + '@MainActor func replace(_ store: RouterStore<R>) async { _ = await store.replaceHost(with: .init(state: .rootStack), descriptor: .init(root: .stack)) }\n', None),
    'host_descriptor_setter_negative': (runtime + '@MainActor func mutate(_ store: RouterStore<R>) { store.hostDescriptor = .init(root: .stack) }\n', r"cannot assign.*'hostDescriptor'|get.only|setter is inaccessible"),
    'host_generation_private_negative': (runtime + '@MainActor func access(_ store: RouterStore<R>) { _ = store.committedValue }\n', r"'committedValue'.*inaccessible|internal.*protection"),
    'scope_replace_host_negative': (runtime + '@MainActor func replace(_ scope: RouterScope<R>) async { _ = await scope.replaceHost(with: .init(state: .rootStack), descriptor: .init(root: .stack)) }\n', r"has no member 'replaceHost'"),
})

if args.only_fixture:
    unknown = set(args.only_fixture) - fixtures.keys()
    if unknown:
        parser.error('Unknown fixture(s): ' + ', '.join(sorted(unknown)))
    fixtures = {name: fixture for name, fixture in fixtures.items() if name in args.only_fixture}
record = {
    'scope': 'external module typechecking against reduced actual-source Linux engine',
    'excluded': ['shipped public product graph', 'SwiftUI', 'ABI/API baseline', 'Apple SDK/full compiler matrix'],
    'build_provenance_sha256': hashlib.sha256(args.build_provenance.read_bytes()).hexdigest(),
    'build_provenance': json.loads(args.build_provenance.read_text()),
    'toolchain': subprocess.check_output(['swiftc', '--version'], text=True).strip(),
    'results': [],
}
for name, (source, diagnostic) in fixtures.items():
    path = args.scratch / (name + '.swift')
    path.write_text(source)
    command = ['swiftc', '-typecheck', '-swift-version', '6', '-strict-concurrency=complete',
               '-warnings-as-errors', '-module-name', 'ExternalBoundaryConsumer',
               '-module-cache-path', str(args.scratch / 'module-cache'), '-I', str(args.modules), str(path)]
    result = subprocess.run(command, capture_output=True, text=True)
    log = result.stdout + result.stderr
    (args.scratch / (name + '.log')).write_text(log)
    passed = (result.returncode == 0 if diagnostic is None else result.returncode != 0 and re.search(diagnostic, log) is not None)
    record['results'].append({'name': name, 'command': command, 'source_sha256': hashlib.sha256(source.encode()).hexdigest(),
                              'exit_code': result.returncode, 'expected_diagnostic': diagnostic, 'passed': passed})
    print(name, 'PASS' if passed else 'FAIL')
(args.scratch / 'provenance.json').write_text(json.dumps(record, indent=2) + '\n')
raise SystemExit(0 if all(item['passed'] for item in record['results']) else 1)
