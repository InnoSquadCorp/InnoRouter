import Foundation
import SwiftUI
import Testing

import InnoRouter
import InnoRouterTesting

@Router
private enum ConsumerTabRoute: Codable {
    @TabItem("Home", systemImage: "house") case home
    @TabItem("Settings", systemImage: "gearshape") case settings
    case detail(String)
    var destination: some View { Text(String(describing: self)) }
}

@Suite("External tab restoration")
@MainActor
struct TabRestorationConsumerTests {
    @Test("Macro catalogs, manual hosts, test stores and snapshots share the public topology")
    func explicitTopologyConsumer() async throws {
        typealias R = ConsumerTabRoute
        let catalog = try RouterTabCatalog(R.routerTabs)
        let topology = RouterTabRestorationTopology(catalog: catalog)
        #expect(topology == (try RouterTabRestorationTopology(of: R.self)))
        let old = try RouterState<R>(root: .container(.init(
            style: .tabs, selection: "legacy", branches: [
                .init(id: "home", node: .stack(path: [.detail("saved")])), .init(id: "legacy"),
            ]
        )))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let data = try codec.encode(old)
        let store = R.makeRouterStore()
        guard case .applied = try await store.restore(from: data, using: codec, tabTopology: topology) else {
            Issue.record("Expected the external explicit restoration to apply")
            return
        }
        _ = try RouterTabHost(store: store, catalog: catalog, allowingOrphanedBranches: true)
        #expect(throws: RouterTabCatalogError.storeBranchesDoNotMatchCatalog) {
            _ = try RouterTabHost(store: store, catalog: catalog)
        }
        let testStore = RouterTestStore<R>()
        let restored = try await testStore.restore(from: data, using: codec, tabTopology: topology)
        guard case .applied(_, _, let testState, _) = restored.transition else {
            Issue.record("Expected test store restoration to apply")
            return
        }
        #expect(testState == store.state)
        testStore.receiveStarted()
        testStore.receiveCommitted { state, revision in state == testState && revision == 1 }
        await testStore.finish()
        let partial = try await store.restorePartially(
            from: data, using: codec, validator: .init { _, _ in .keep }, tabTopology: topology
        )
        #expect(partial.report.topologyChanges.contains(.insertedScope("settings")))
        _ = await store.perform(.select("settings"))
        _ = await store.scope(at: ["settings"]).perform(.push(.detail("next")))
        _ = await store.scope(at: ["settings"]).perform(.pop(count: 1))
        #expect(store.scope(at: ["settings"]).node == .stack())
        let saved = try await store.snapshot(using: codec)
        let reopened = R.makeRouterStore()
        _ = try await reopened.restore(from: saved, using: codec, tabTopology: topology)
        #expect(reopened.state == store.state)
    }
}
