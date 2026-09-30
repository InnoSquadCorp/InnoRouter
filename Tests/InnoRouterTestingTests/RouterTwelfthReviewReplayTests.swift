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
    @Test func ordinaryFeatureActionMustReplayOwnership() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.home)])
        let deferralID = RouterDeferralID()
        let config = RouterStoreConfiguration<ReplayRoot>(policies: [RouterPolicy(name: "approval") { transition in
            if case .push = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(deferralID) }
            return .allow
        }])
        let source = RouterStore(initialState: initial, configuration: config)
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
        let missingResolverTarget = RouterTestStore(
            initialState: initial,
            configuration: config,
            exhaustivity: .off
        )
        await #expect(throws: (any Error).self) {
            _ = try await RouterScenarioRunner.replay(decoded, on: missingResolverTarget)
        }
        #expect(missingResolverTarget.state == initial)
        await missingResolverTarget.finish()

        let target = RouterTestStore(initialState: initial, configuration: config, exhaustivity: .off)
        do {
            _ = try await RouterScenarioRunner.replay(decoded, on: target, featureResolvers: [.init(replayMapping)])
        } catch {
            Issue.record("Valid feature action capture cannot replay: \(error); state: \(target.state)")
        }
        #expect(target.state == .rootStack(path: [.sibling]))
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test func featurePresentationAndCompletionRoundTripOwnership() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.home)])
        let source = RouterStore(initialState: initial)
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
        let target = RouterTestStore<ReplayRoot>(
            initialState: initial,
            exhaustivity: .off
        )
        _ = try await RouterScenarioRunner.replay(
            fixture,
            on: target,
            featureResolvers: [.init(replayMapping)]
        )
        #expect(target.state == initial)
        target.skipReceivedEvents()
        await target.finish()
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
            .replacingOccurrences(of: "\"formatVersion\":7", with: "\"formatVersion\":6")
        #expect(throws: RouterScenarioFixtureError.self) {
            _ = try RouterScenarioFixture<ReplayRoot>.decode(from: Data(text.utf8))
        }
    }

    @Test func expiredWindowLifetimeRoundTripsWithoutAuthorizingReplacement() async throws {
        let windowID = UUID()
        let first = try RouterState<ReplayRoot>(windows: [.init(
            id: windowID,
            route: .feature(.home),
            node: .stack(path: [.feature(.home)])
        )])
        let source = RouterStore(initialState: first)
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
        guard case .rejected = live else {
            Issue.record("Expected the stale Scene request to reject")
            return
        }
        #expect(await recorder.waitUntilCaptured(1))
        let captured = recorder.stop()
        guard case .featureAction(_, .expiredScene, _) = captured.steps.first?.requestSemantics else {
            Issue.record("Expected an expired logical Scene lifetime")
            return
        }
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal,
                rejection: $0.observedRejection
            )
        })
        let target = RouterTestStore<ReplayRoot>(
            initialState: replacement,
            exhaustivity: .off
        )
        let outcomes = try await RouterScenarioRunner.replay(
            fixture,
            on: target,
            featureResolvers: [.init(replayMapping)]
        )
        #expect(outcomes.count == 1)
        #expect(target.state == replacement)
        #expect(target.revision == 0)
        target.skipReceivedEvents()
        await target.finish()
    }

    @Test func nestedFeatureMustReplayOuterOwnerFailure() async throws {
        let initial: RouterState<ReplayRoot> = .rootStack(path: [.feature(.leaf(.home))])
        let deferralID = RouterDeferralID()
        let config = RouterStoreConfiguration<ReplayRoot>(policies: [RouterPolicy(name: "approval") { transition in
            if case .apply = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(deferralID) }
            return .allow
        }])
        let source = RouterStore(initialState: initial, configuration: config)
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
        let target = RouterTestStore(initialState: initial, configuration: config, exhaustivity: .off)
        do {
            _ = try await RouterScenarioRunner.replay(fixture, on: target, featureResolvers: [
                RouterScenarioFeatureProjection(replayMapping).appending(replayLeafMapping).eraseToResolver()
            ])
        } catch {
            Issue.record("Valid outer-owner rejection cannot replay: \(error)")
        }
        target.skipReceivedEvents()
        await target.finish()
    }
}
