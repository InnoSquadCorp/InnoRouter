import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

/// Behavior of the caller-supplied tab topology introduced by RBR-T04.
@Suite("RouterTabRestorationTopology")
struct RouterTabRestorationTopologyTests {
    private enum TopologyRoute: String, Route, Codable {
        case home
        case detail
        case settings
        case recovered
    }

    private static let presentationID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000C1"
    )!

    private static func tabs(
        selection: RouterScopeID,
        _ branches: [RouterBranch<TopologyRoute>],
        badges: [RouterScopeID: Int] = [:]
    ) throws -> RouterState<TopologyRoute> {
        try RouterState(
            root: .container(
                try RouterContainerState(
                    style: .tabs,
                    selection: selection,
                    branches: branches,
                    badges: badges
                )
            )
        )
    }

    private static func container(
        _ state: RouterState<TopologyRoute>
    ) -> RouterContainerState<TopologyRoute>? {
        guard case .container(let container) = state.root else { return nil }
        return container
    }

    // MARK: - Pure reconciliation

    @Test("A scope the snapshot carries is kept exactly")
    func keepsExistingScopesExactly() throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home", "settings"])
        let snapshot = try Self.tabs(
            selection: "settings",
            [
                .init(id: "home", node: .stack(path: [.detail])),
                .init(
                    id: "settings",
                    node: .stack(
                        path: [.settings],
                        presentation: .init(
                            id: Self.presentationID,
                            route: .detail,
                            style: .sheet
                        )
                    )
                ),
            ],
            badges: ["settings": 3]
        )

        let reconciled = try topology.reconciling(snapshot)

        #expect(reconciled == snapshot)
    }

    @Test("A scope the snapshot lacks is created empty and unbadged")
    func createsMissingScopesEmpty() throws {
        let topology = try RouterTabRestorationTopology(
            scopeIDs: ["home", "settings", "profile"]
        )
        let snapshot = try Self.tabs(
            selection: "home",
            [.init(id: "home", node: .stack(path: [.detail]))],
            badges: ["home": 1]
        )

        let container = try #require(Self.container(try topology.reconciling(snapshot)))

        #expect(container.branches.map(\.id) == ["home", "settings", "profile"])
        #expect(container.branches[1].node == .stack())
        #expect(container.branches[2].node == .stack())
        #expect(container.badges == ["home": 1])
    }

    @Test("A selection the topology no longer names falls back to its first scope")
    func removedSelectionFallsBackToFirstScope() throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home", "settings"])
        let snapshot = try Self.tabs(
            selection: "legacy",
            [
                .init(id: "home", node: .stack()),
                .init(id: "legacy", node: .stack(path: [.detail])),
            ]
        )

        let container = try #require(Self.container(try topology.reconciling(snapshot)))

        #expect(container.selection == "home")
    }

    @Test("A branch the topology does not name is preserved after current scopes")
    func orphanBranchesArePreservedInOrder() throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home", "settings"])
        let snapshot = try Self.tabs(
            selection: "home",
            [
                .init(id: "legacyA", node: .stack(path: [.detail])),
                .init(id: "home", node: .stack()),
                .init(id: "legacyB", node: .stack(path: [.settings])),
            ],
            badges: ["legacyA": 5]
        )

        let container = try #require(Self.container(try topology.reconciling(snapshot)))

        #expect(container.branches.map(\.id) == ["home", "settings", "legacyA", "legacyB"])
        #expect(container.branches[2].node == .stack(path: [.detail]))
        #expect(container.badges == ["legacyA": 5])
    }

    @Test("Windows and the immersive space are untouched")
    func windowsAndImmersiveSpaceAreUntouched() throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home", "settings"])
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        let snapshot = try RouterState<TopologyRoute>(
            root: .container(
                try RouterContainerState(
                    style: .tabs,
                    selection: "home",
                    branches: [.init(id: "home", node: .stack())]
                )
            ),
            windows: [.init(id: windowID, route: .detail, node: .stack(path: [.settings]))],
            immersiveSpace: .init(id: "space", route: .detail)
        )

        let reconciled = try topology.reconciling(snapshot)

        #expect(reconciled.windows == snapshot.windows)
        #expect(reconciled.immersiveSpace == snapshot.immersiveSpace)
    }

    @Test("A root that is not a tabs container is a typed failure")
    func rootThatIsNotTabsIsATypedFailure() throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home"])
        let snapshot = try RouterState<TopologyRoute>(root: .stack(path: [.home]))

        #expect(throws: RouterTabRestorationError.rootIsNotTabs) {
            _ = try topology.reconciling(snapshot)
        }
    }

    @Test("A topology must name at least one unique scope")
    func topologyValidatesItsOwnInput() throws {
        #expect(throws: RouterTabRestorationError.emptyTopology) {
            _ = try RouterTabRestorationTopology(scopeIDs: [])
        }
        #expect(throws: RouterTabRestorationError.duplicateScopeID("home")) {
            _ = try RouterTabRestorationTopology(scopeIDs: ["home", "home"])
        }
    }

    // MARK: - Store integration

    @Test("Partial restoration validates the reconciled candidate")
    @MainActor
    func partialRestorationValidatesTheReconciledCandidate() async throws {
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [.init(id: "home", node: .stack(path: [.settings]))]
            )
        )
        let codec = try RouterSnapshotCodec<TopologyRoute>(currentVersion: 1)
        let data = try codec.encode(
            try Self.tabs(
                selection: "home",
                [.init(id: "home", node: .stack(path: [.detail]))]
            )
        )
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home", "profile"])
        let observed = ValidationLog()

        let outcome = try await store.restorePartially(
            from: data,
            using: codec,
            validator: .init { route, _ in
                observed.record(route)
                return .keep
            },
            tabTopology: topology
        )

        guard case .applied(_, _, let restored, _) = outcome.transition else {
            Issue.record("Expected one applied transition, got \(outcome.transition)")
            return
        }
        let container = try #require(Self.container(restored))
        #expect(container.branches.map(\.id) == ["home", "profile"])
        // The created scope is empty, so it contributes nothing to validate,
        // and nothing was added to the candidate after validation ran.
        #expect(observed.routes == [.detail])
        #expect(container.branches[1].node == .stack())
    }

    @Test("A recovery fallback is applied exactly even with a topology")
    @MainActor
    func recoveryFallbackIsNotReconciled() async throws {
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [.init(id: "home", node: .stack())]
            )
        )
        let codec = try RouterSnapshotCodec<TopologyRoute>(currentVersion: 1)
        let fallback = try RouterState<TopologyRoute>(root: .stack(path: [.recovered]))
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home", "profile"])

        let outcome = try await store.restore(
            from: Data("not a snapshot".utf8),
            using: codec,
            recovery: .use { _ in fallback },
            tabTopology: topology
        )

        guard case .recovered = outcome.decoding else {
            Issue.record("Expected the corrupt payload to reach the recovery policy")
            return
        }
        #expect(store.state == fallback)
    }

    @Test("An equivalent snapshot commits nothing")
    @MainActor
    func equivalentSnapshotIsUnchanged() async throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["home", "profile"])
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack(path: [.detail])),
                    .init(id: "profile", node: .stack()),
                ]
            )
        )
        let codec = try RouterSnapshotCodec<TopologyRoute>(currentVersion: 1)
        // Written before `profile` existed; reconciliation recreates it empty.
        let data = try codec.encode(
            try Self.tabs(
                selection: "home",
                [.init(id: "home", node: .stack(path: [.detail]))]
            )
        )
        let before = store.revision

        let outcome = try await store.restore(from: data, using: codec, tabTopology: topology)

        guard case .unchanged = outcome else {
            Issue.record("Expected an equivalent candidate to commit nothing, got \(outcome)")
            return
        }
        #expect(store.revision == before)
    }

    @MainActor
    private final class ValidationLog {
        private(set) var routes: [TopologyRoute] = []
        func record(_ route: TopologyRoute) { routes.append(route) }
    }
}
