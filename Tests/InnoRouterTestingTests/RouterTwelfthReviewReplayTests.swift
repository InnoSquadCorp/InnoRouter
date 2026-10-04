// MARK: - RouterTwelfthReviewReplayTests.swift
import Foundation
import Testing
import InnoRouter
import InnoRouterTesting

private enum ReplayLeaf: Route, Codable { case home, detail }
private enum ReplayChild: Route, Codable { case home, detail, leaf(ReplayLeaf) }
private enum ReplayRoot: Route, Codable { case feature(ReplayChild), sibling }
private let replayMapping = RouterFeatureMapping<ReplayRoot, ReplayChild>(
    id: "feature", namespace: "ReplayRoot.feature",
    route: .init(embed: ReplayRoot.feature, extract: {
        guard case .feature(let route) = $0 else { return nil }
        return route
    })
)
private let replayLeafMapping = RouterFeatureMapping<ReplayChild, ReplayLeaf>(
    id: "leaf", namespace: "ReplayChild.leaf",
    route: .init(embed: ReplayChild.leaf, extract: {
        guard case .leaf(let route) = $0 else { return nil }
        return route
    })
)

@Suite @MainActor
struct RouterTwelfthReviewReplayTests {
    @Test("Authored declarative feature scenarios retain resolver and generation contracts")
    func authoredFeatureScenarioUsesExplicitResolver() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.home)])
        let expected: RouterState<ReplayRoot> = .rootStack(path: [.feature(.home), .feature(.detail)])
        let entry = RouterFeatureCatalogEntry(
            id: replayMapping.id, namespace: replayMapping.namespace,
            childRouteTypeName: String(describing: ReplayChild.self)
        )
        let fixture = RouterScenarioFixture(initialState: initial, steps: [
            RouterScenarioStep(
                action: RouterAction<ReplayRoot>.push(.feature(.detail)),
                context: .init(),
                requestSemantics: .featureAction(scope: .root, lifetime: .application, features: [entry]),
                observedState: expected, observedRevision: 1, observedTerminal: .applied,
                expectation: .init(state: expected, revision: 1, terminal: .applied)
            ),
        ])
        #expect(throws: RouterScenarioSourceGenerationError.missingFeatureResolversFactory) {
            _ = try RouterScenarioSourceGenerator.generate(fixture, routeTypeName: "ReplayRoot")
        }
        _ = try RouterScenarioSourceGenerator.generateFiles(
            fixture, routeTypeName: "ReplayRoot", featureResolversFactory: "makeReplayResolvers"
        )
        let target = try RouterTestStore(initialState: initial, exhaustivity: .off)
        await #expect(throws: RouterScenarioReplayError.missingFeatureResolver(namespaces: [replayMapping.namespace])) {
            _ = try await RouterScenarioRunner.replay(fixture, on: target)
        }
        await #expect(throws: RouterScenarioReplayError.duplicateFeatureResolver(namespaces: [replayMapping.namespace])) {
            _ = try await RouterScenarioRunner.replay(
                fixture, on: target, featureResolvers: [.init(replayMapping), .init(replayMapping)]
            )
        }
        #expect(target.state == initial)
        #expect(target.revision == 0)
        _ = try await RouterScenarioRunner.replay(fixture, on: target, featureResolvers: [.init(replayMapping)])
        #expect(target.state == expected)
        #expect(target.revision == 1)
        await target.finish()
    }

    @Test func ordinaryFeatureActionRecordsUnsupportedRuntimeOwnership() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.home)])
        let deferralID = RouterDeferralID()
        let config = RouterStoreConfiguration<ReplayRoot>(policies: [RouterPolicy(name: "approval") { transition in
            if case .push = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(deferralID) }
            return .allow
        }])
        let source = try RouterStore(initialState: initial, configuration: config)
        let recorder = RouterScenarioRecorder(store: source)
        let feature = RouterFeatureScope(parent: source.scope(), mapping: replayMapping)
        _ = await feature.perform(.push(.detail))
        _ = await source.perform(.replaceStack([.sibling]))
        let live = await recorder.resolveDeferred(deferralID, with: .allow, resumeStrategy: .rebaseOnCurrentState)
        guard case .rejected(_, _, _, .featureProjection) = live else { Issue.record("Expected live ownership rejection"); return }
        #expect(await recorder.waitUntilCaptured(3))
        let captured = recorder.stop()
        #expect(captured.formatVersion == RouterScenarioFixture<ReplayRoot>.currentFormatVersion)
        #expect(captured.steps.contains { step in
            guard case .featureAction(let scope, let lifetime, let features) = step.requestSemantics else {
                return false
            }
            return scope == .root
                && lifetime == .application
                && features.map(\.namespace) == ["ReplayRoot.feature"]
        })
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(state: $0.observedState, revision: $0.observedRevision, terminal: $0.observedTerminal, rejection: $0.observedRejection)
        })
        let decoded = try RouterScenarioFixture<ReplayRoot>.decode(from: JSONEncoder().encode(fixture))
        #expect(source.state == .rootStack(path: [.sibling]))
        try await assertCapturedReplayUnsupported(decoded, code: .runtimeExecutionPrecondition)
    }

    @Test func featurePresentationAndCompletionRecordRuntimeAuthority() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.home)])
        let source = try RouterStore(initialState: initial)
        let recorder = RouterScenarioRecorder(store: source)
        let feature = RouterFeatureScope(parent: source.scope(), mapping: replayMapping)
        let result = Task { @MainActor in
            await feature.present(.detail, expecting: String.self)
        }
        #expect(await recorder.waitUntilCaptured(1))
        try await feature.finishPresentation(returning: "done")
        #expect(await result.value == .value("done"))
        #expect(await recorder.waitUntilCaptured(2))
        let captured = recorder.stop()
        #expect(captured.steps.allSatisfy { step in
            guard case .featureAction(let scope, let lifetime, let features) = step.requestSemantics else {
                return false
            }
            return scope == .root
                && lifetime == .application
                && features.map(\.namespace) == ["ReplayRoot.feature"]
        })
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        #expect(source.state == initial)
        try await assertCapturedReplayUnsupported(fixture, code: .runtimeExecutionPrecondition)
    }

    @Test func formatSixFeatureSemanticsAreRejectedBeforeReplay() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.home)])
        let step = RouterScenarioStep(
            action: RouterAction<ReplayRoot>.push(.feature(.detail)),
            context: .init(),
            requestSemantics: .featureAction(
                scope: .root,
                lifetime: .application,
                features: [.init(
                    id: replayMapping.id,
                    namespace: replayMapping.namespace,
                    childRouteTypeName: String(describing: ReplayChild.self)
                )]
            ),
            observedState: initial,
            observedRevision: 0,
            observedTerminal: .rejected,
            observedRejection: .featureProjection,
            expectation: .init(
                state: initial,
                revision: 0,
                terminal: .rejected,
                rejection: .featureProjection
            )
        )
        let fixture = RouterScenarioFixture(initialState: initial, steps: [step])
        let encoded = try JSONEncoder().encode(fixture)
        let text = try #require(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: "\"formatVersion\":8", with: "\"formatVersion\":6")
        #expect(throws: RouterScenarioFixtureError.self) {
            _ = try RouterScenarioFixture<ReplayRoot>.decode(from: Data(text.utf8))
        }
    }

    @Test func expiredWindowProjectionRejectsBeforeStoreCapture() async throws {
        let windowID = UUID()
        let first = try RouterState<ReplayRoot>(windows: [.init(
            id: windowID,
            route: .feature(.home),
            node: .stack(path: [.feature(.home)])
        )])
        let source = try RouterStore(initialState: first)
        let staleFeature = RouterFeatureScope(
            parent: source.scope(at: .window(windowID)),
            mapping: replayMapping
        )
        _ = await source.perform(.dismissWindow(windowID))
        _ = await source.perform(.openWindow(.init(
            id: windowID,
            route: .feature(.home),
            node: .stack(path: [.feature(.home)])
        )))
        let replacement = source.state
        let recorder = RouterScenarioRecorder(store: source)
        let live = await staleFeature.perform(.push(.detail))
        guard case .rejected(_, _, _, .featureProjection) = live else {
            Issue.record("Expected the stale feature projection to reject before Store submission")
            return
        }
        // An inert projection rejects before reaching the Store. Capture must
        // not fabricate a submission; its unmatched rejection stays incomplete.
        let captured = recorder.stop()
        #expect(captured.steps.isEmpty)
        #expect(!captured.completeness.isComplete)
        #expect(captured.completeness.unpairedRequestCount == 1)
        #expect(throws: RouterScenarioSourceGenerationError.incomplete(captured.completeness)) {
            _ = try RouterScenarioSourceGenerator.generate(captured, routeTypeName: "ReplayRoot")
        }
        #expect(source.state == replacement)
        #expect(source.revision == captured.initialRevision)
    }

    @Test func nestedFeatureCapturesOuterOwnerFailureWithoutReplayingTokens() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.leaf(.home))])
        let deferralID = RouterDeferralID()
        let config = RouterStoreConfiguration<ReplayRoot>(policies: [RouterPolicy(name: "approval") { transition in
            if case .apply = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(deferralID) }
            return .allow
        }])
        let source = try RouterStore(initialState: initial, configuration: config)
        let recorder = RouterScenarioRecorder(store: source)
        let feature = RouterFeatureScope(parent: source.scope(), mapping: replayMapping)
        let leaf = RouterFeatureScope(parent: feature, mapping: replayLeafMapping)
        _ = await leaf.perform(.apply(.init(state: .rootStack(path: [.detail]))))
        _ = await source.perform(.replaceStack([.sibling]))
        _ = await recorder.resolveDeferred(deferralID, with: .allow, resumeStrategy: .rebaseOnCurrentState)
        #expect(await recorder.waitUntilCaptured(3))
        let captured = recorder.stop()
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(state: $0.observedState, revision: $0.observedRevision, terminal: $0.observedTerminal, rejection: $0.observedRejection)
        })
        #expect(source.state == .rootStack(path: [.sibling]))
        try await assertCapturedReplayUnsupported(fixture, code: .runtimeOwnershipReplacement)
    }
}
