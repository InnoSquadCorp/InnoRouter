import Foundation

import InnoRouter
import InnoRouterInspector
import InnoRouterTesting

private enum DeveloperToolsSmokeRoute: String, Route, Codable, DeepLinkRoute {
    case detail

    static func resolveDeepLink(_ url: URL) -> Self? {
        url.path == "/detail" ? .detail : nil
    }

    func deepLinkURL(origin: DeepLinkOrigin) -> URL? {
        DeepLinkURLBuilder.makeURL(origin: origin, pattern: "/detail")
    }
}

@MainActor
enum DeveloperToolsSmokeConsumer {
    static func exercise() async throws {
        let diagnostics = RouterObservability<DeveloperToolsSmokeRoute> { _ in }
        let runtime = RouterStore<DeveloperToolsSmokeRoute>(
            configuration: RouterStoreConfiguration().observing(diagnostics)
        )
        let reader = RouterStateReader(scope: runtime.scope())
        let recorder = RouterInspectorRecorder()
        let subscription = recorder.attach(to: runtime)
        let scenario = RouterInspectorScenarioController.routerScenario(store: runtime)
        scenario.start()

        _ = await runtime.perform(.push(.detail))
        scenario.refreshProgress()
        scenario.stop()
        _ = scenario.rawExportData()
        _ = reader.canGoBack
        _ = RouterInspectorProjection.tree(from: runtime.state)
        _ = RouterInspectorProjection.diff(from: .rootStack, to: runtime.state)

        let exported = try recorder.encodedSnapshot()
        let imported = try recorder.importSnapshot(from: exported)
        let playback = RouterInspectorPlayback(snapshot: imported)
        _ = playback.currentEntry
        _ = try recorder.importDiagnosticBundle(from: recorder.encodedDiagnosticBundle())

        let testStore = RouterTestStore<DeveloperToolsSmokeRoute>()
        _ = await testStore.send(
            RouterPlan(state: .rootStack(path: [.detail])),
            context: .init(source: .inspector)
        )
        testStore.skipReceivedEvents()
        let sequence = RouterActionSequence<DeveloperToolsSmokeRoute>(steps: [
            .init(action: .popToRoot, context: .init(source: .deepLink, requestKey: "smoke")),
        ])
        _ = await sequence.replay(on: testStore)
        testStore.skipReceivedEvents()
        await testStore.finish()

        let codec = try RouterSnapshotCodec<DeveloperToolsSmokeRoute>(currentVersion: 1)
        _ = RouterRestorationDriver(
            store: runtime,
            codec: codec,
            storage: RouterFileSnapshotStorage(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("innorouter-smoke.snapshot")
            )
        )

        let origin = DeepLinkOrigin(scheme: "innorouter", host: "app")!
        _ = RouterShortcutCatalog(
            origin: origin,
            entries: [
                RouterShortcutRoute<DeveloperToolsSmokeRoute>(
                    id: "detail",
                    route: .detail
                )
            ]
        )

        subscription.cancel()
    }
}
