import Foundation
import Testing

import InnoRouter
import InnoRouterInspector
import InnoRouterMacroFirstExternalConsumer
import InnoRouterTesting
import FeatureCompositionConsumer

@Suite("InnoRouter 6 downstream product boundary")
struct CanonicalPublicAPITests {
    private enum SnapshotRoute: String, Route, Codable {
        case home
        case fallback
    }

    @Test("Independent feature modules compose through one parent store")
    @MainActor
    func featureComposition() async {
        let state = await exerciseFeatureComposition()
        #expect(
            state.root == .stack(
                path: [
                    .account(.overview),
                    .account(.profile(userID: "external-consumer")),
                ]
            )
        )
    }

    @Test("Independent feature origins render and resolve through the parent")
    func featureDeepLinkOrigins() {
        let urls = exerciseFeatureDeepLinkOrigins()

        #expect(urls.map(\.absoluteString) == [
            "account://account.example.com/profile/42",
            "search://search.example.com/result/99",
        ])
        #expect(urls.compactMap(ComposedAppRoute.resolveDeepLink) == [
            .account(.profile(userID: "42")),
            .search(.result(id: "99")),
        ])
    }

    @Test("Independent feature modules isolate two same-kind windows and a typed modal result")
    @MainActor
    func featureWindowPresentationIntegration() async throws {
        let result = try await exerciseFeatureWindowIntegration()

        #expect(result.modalValue == "saved")
        #expect(result.state.windows.map(\.id) == [
            result.accountWindowID,
            result.searchWindowID,
        ])
        #expect(result.state.windows[0].route == .account(.overview))
        #expect(result.state.windows[0].node == .stack())
        #expect(result.state.windows[1].route == .search(.results(query: "swift")))
        #expect(result.state.windows[1].node == .stack(path: [.search(.result(id: "42"))]))
    }

    @Test @MainActor
    func testingAndInspectorProductsComposeWithCanonicalStore() async {
        let testStore = RouterTestStore<ExternalRoute>()

        _ = await testStore.send(.push(.detail(id: "consumer")))
        testStore.receiveStarted()
        testStore.receiveCommitted { state, revision in
            state == .rootStack(path: [.detail(id: "consumer")]) && revision == 1
        }
        await testStore.finish()

        let liveStore = ExternalRoute.makeRouterStore()
        let recorder = RouterInspectorRecorder(capacity: 4)
        let subscription = recorder.attach(to: liveStore)
        subscription.cancel()
    }

    @Test @MainActor
    func contextualFixturesAndDiagnosticBundlesRoundTrip() async throws {
        let context = RouterTransitionContext(source: .deepLink, requestKey: "consumer-link")
        let fixture = RouterActionSequence<ExternalRoute>(steps: [
            .init(action: .push(.detail(id: "consumer")), context: context),
        ])
        let restoredFixture = try RouterActionSequence<ExternalRoute>.decode(fixture.encoded())
        let testStore = RouterTestStore<ExternalRoute>()
        _ = await restoredFixture.replay(on: testStore)
        testStore.receiveStarted { $0.context == context }
        testStore.receiveCommitted { state, _ in
            state == .rootStack(path: [.detail(id: "consumer")])
        }
        await testStore.finish()

        let recorder = RouterInspectorRecorder()
        recorder.record(domain: .router, description: .init(name: "consumer"))
        let imported = try RouterInspectorRecorder().importDiagnosticBundle(
            from: recorder.encodedDiagnosticBundle()
        )
        #expect(imported.frameworkVersion == InnoRouterVersion.current)
        #expect(imported.snapshot.entries == recorder.entries)
    }

    @Test("6.0 capability additions are independently consumable")
    @MainActor
    func capabilityAdditions() async throws {
        let url = try #require(
            URL(string: "innorouter://app.example.com/details/external")
        )
        let analysis = RouterInspectorDeepLinkAnalyzer.analyze(url, as: ExternalRoute.self)
        #expect(analysis.decision == "accepted detail via /details/:id")
        #expect(analysis.catalog.entries.map(\.routeCase) == ["detail", "shadowed"])
        #expect(
            analysis.catalog.entries[1].parameters[0].isApplicationConversionRequired
        )

        let codec = try RouterSnapshotCodec<ExternalRoute>(currentVersion: 1)
        let snapshot = try codec.encode(.rootStack(path: [.detail(id: "restored")]))
        let liveStore = ExternalRoute.makeRouterStore()
        let restored = try await liveStore.restorePartially(
            from: snapshot,
            using: codec,
            validator: .init { _, _ in .keep }
        )
        guard case .applied = restored.transition else {
            Issue.record("Expected downstream partial restoration to apply")
            return
        }

        let history = RouterHistory(store: liveStore)
        _ = await liveStore.perform(.push(.settings))
        #expect(await history.waitUntilRecorded(2))
        guard case .completed = await history.goBack() else {
            Issue.record("Expected downstream history back")
            return
        }
        #expect(liveStore.state == .rootStack(path: [.detail(id: "restored")]))
        history.stop()

        let recorder = RouterScenarioRecorder(store: liveStore)
        _ = await liveStore.perform(.push(.home))
        #expect(await recorder.waitUntilCaptured(1))
        let captured = recorder.stop()
        let fixture = try captured.settingExpectations(captured.steps.map {
            .init(
                state: $0.observedState,
                revision: $0.observedRevision,
                terminal: $0.observedTerminal
            )
        })
        let source = try RouterScenarioSourceGenerator.generate(
            fixture,
            routeTypeName: "ExternalRoute",
            storeFactory: "makeExternalTestStore"
        )
        #expect(source.contains("RouterScenarioFixture<ExternalRoute>"))
    }

    @Test("Snapshot migration failures preserve the published recovery contract")
    func snapshotMigrationFailureCompatibility() throws {
        let oldCodec = try RouterSnapshotCodec<SnapshotRoute>(currentVersion: 1)
        let encoded = try oldCodec.encode(.rootStack(path: [.home]))
        let codec = try RouterSnapshotCodec<SnapshotRoute>(
            currentVersion: 2,
            migrations: [
                .init(from: 1, to: 2) { _ in
                    throw RouterSnapshotError.invalidSnapshotVersion(0)
                },
            ]
        )

        let result = try codec.decode(encoded, recovery: .use { error in
            guard case .migrationFailed = error else { return .rootStack }
            return .rootStack(path: [.fallback])
        })
        guard case .recovered(let state, let reason) = result else {
            Issue.record("Expected explicit migration recovery")
            return
        }
        #expect(state == .rootStack(path: [.fallback]))
        guard case .migrationFailed(let from, let to, _) = reason else {
            Issue.record("Expected the published migrationFailed wrapper")
            return
        }
        #expect(from == 1)
        #expect(to == 2)
    }

    @Test("A downstream router may own a type named String")
    func downstreamStringShadowing() throws {
        let url = try #require(
            URL(string: "innorouter://shadow-string.example.com/items/external")
        )

        #expect(
            ExternalStringShadowRoute.deepLinkCatalog.entries.map(\.routeCase) == ["item"]
        )
        guard case .item(let id) = ExternalStringShadowRoute.resolveDeepLink(url) else {
            Issue.record("Expected the downstream custom String payload to resolve")
            return
        }
        #expect(id.rawValue == "external")
    }
}
