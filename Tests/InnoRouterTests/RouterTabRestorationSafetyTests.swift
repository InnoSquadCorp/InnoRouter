import Foundation
import Synchronization
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private struct TabSafetyStorage: RouterSnapshotStorage {
    let data: Data
    func load() throws -> Data? { data }
    func save(_ data: Data) throws {}
    func remove() throws {}
}

private final class TabSnapshotDecodeGate: Sendable {
    static let active = Mutex<TabSnapshotDecodeGate?>(nil)
    let entered = AsyncStream<Void>.makeStream()
    private let signal = DispatchSemaphore(value: 0)

    func release() { signal.signal() }

    func block() throws {
        entered.continuation.yield(())
        entered.continuation.finish()
        guard signal.wait(timeout: .now() + 5) == .success else {
            throw GateError.timedOut
        }
    }

    func waitUntilEntered() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in self.entered.stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private enum GateError: Error { case timedOut }
}

private enum TabSafetyRoute: String, Codable, DestinationRoute, RouterTabRoute {
    case home, settings, storedDetail, newerDetail

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let route = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown route")
        }
        self = route
        if self == .storedDetail,
           let gate = TabSnapshotDecodeGate.active.withLock({ value in
               let gate = value
               value = nil
               return gate
           }) {
            try gate.block()
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    enum Tab: String, RouterTab {
        case home, settings
        var title: LocalizedStringResource { self == .home ? "Home" : "Settings" }
        var systemImage: String { "circle" }
        var routerScopeID: RouterScopeID { .init(rawValue) }
    }

    static let routerTabs: [RouterTabDescriptor<Self, Tab>] = [
        .init(tab: .home, root: .home), .init(tab: .settings, root: .settings),
    ]

    static func destination(for route: Self) -> some View { Text(route.rawValue) }
}

@Suite("Tab restoration safety", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterTabRestorationSafetyTests {
    private typealias R = TabSafetyRoute

    enum EntryPoint: CaseIterable, Sendable {
        case direct, recovery, partial, explicitRevision, exact
    }

    private func tabs(
        _ branches: [RouterBranch<R>], selection: RouterScopeID = "home"
    ) throws -> RouterState<R> {
        try .init(root: .container(.init(style: .tabs, selection: selection, branches: branches)))
    }

    @Test("Decode cannot overwrite a newer navigation; legacy exact restore stays exact",
          arguments: EntryPoint.allCases)
    func newerNavigationDuringDecode(_ entry: EntryPoint) async throws {
        let initial = try tabs([.init(id: "home"), .init(id: "settings")])
        let stored = try tabs([.init(id: "home", node: .stack(path: [.storedDetail]))])
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let data = try codec.encode(stored)
        let topology = try RouterTabRestorationTopology(of: R.self)
        let store = RouterStore(initialState: initial)
        let gate = TabSnapshotDecodeGate()
        TabSnapshotDecodeGate.active.withLock { $0 = gate }
        defer {
            gate.release()
            TabSnapshotDecodeGate.active.withLock { $0 = nil }
        }
        let task = Task { @MainActor in
            switch entry {
            case .direct:
                return try await store.restore(from: data, using: codec, tabTopology: topology)
            case .recovery:
                return try await store.restore(
                    from: data, using: codec, recovery: .fail, tabTopology: topology
                ).transition
            case .partial:
                return try await store.restorePartially(
                    from: data, using: codec, validator: .init { _, _ in .keep }, tabTopology: topology
                ).transition
            case .explicitRevision:
                return try await store.restore(
                    from: data, using: codec, tabTopology: topology, expectedRevision: 0
                )
            case .exact:
                return try await store.restore(from: data, using: codec)
            }
        }
        defer { task.cancel() }
        guard await gate.waitUntilEntered() else {
            Issue.record("Snapshot decoder did not reach its barrier")
            return
        }
        _ = await store.scope(at: ["home"]).perform(.push(.newerDetail))
        let newerState = store.state
        gate.release()
        let result = try await task.value
        if entry == .exact {
            guard case .applied = result else { Issue.record("Legacy exact contract changed"); return }
            #expect(store.state == stored)
        } else {
            guard case .rejected(_, _, _, .staleState(expectedRevision: 0, actualRevision: 1)) = result else {
                Issue.record("Expected stale decode to be rejected, got \(result)")
                return
            }
            #expect(store.state == newerState)
            #expect(store.revision == 1)
        }
    }

    @Test("Cancellation during decode commits nothing", arguments: [false, true])
    func cancellationDuringDecode(recovery: Bool) async throws {
        let initial = try tabs([.init(id: "home"), .init(id: "settings")])
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let data = try codec.encode(tabs([.init(id: "home", node: .stack(path: [.storedDetail]))]))
        let topology = try RouterTabRestorationTopology(of: R.self)
        let store = RouterStore(initialState: initial)
        let gate = TabSnapshotDecodeGate()
        TabSnapshotDecodeGate.active.withLock { $0 = gate }
        defer {
            gate.release()
            TabSnapshotDecodeGate.active.withLock { $0 = nil }
        }
        let task = Task { @MainActor in
            if recovery {
                return try await store.restore(
                    from: data, using: codec, recovery: .fail, tabTopology: topology
                ).transition
            }
            return try await store.restore(from: data, using: codec, tabTopology: topology)
        }
        defer { task.cancel() }
        guard await gate.waitUntilEntered() else { Issue.record("Decoder did not enter"); return }
        task.cancel()
        gate.release()
        let result = try await task.value
        guard case .rejected(_, _, _, .cancelled) = result else {
            Issue.record("Expected cancellation, got \(result)")
            return
        }
        #expect(store.state == initial)
        #expect(store.revision == 0)
    }

    @Test("Mutable invalid state produces a typed failure instead of a Dictionary trap")
    func invalidMutableState() throws {
        var state = try tabs([.init(id: "home")])
        guard case .container(var container) = state.root else { return }
        container.branches.append(.init(id: "home"))
        state.root = .container(container)
        let topology = try RouterTabRestorationTopology(of: R.self)
        #expect(throws: RouterStateValidationError.duplicateScope) {
            _ = try topology.reconciling(state)
        }
    }

    @Test("Current tabs must be stacks before restoration or host construction")
    func nonStackCurrentBranch() async throws {
        let nested = try RouterContainerState<R>(style: .custom("nested"), branches: [.init(id: "child")])
        let snapshot = try tabs([.init(id: "home"), .init(id: "settings", node: .container(nested))])
        let initial = try tabs([.init(id: "home"), .init(id: "settings")])
        let topology = try RouterTabRestorationTopology(of: R.self)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let data = try codec.encode(snapshot)
        let store = RouterStore(initialState: initial)
        await #expect(throws: RouterMutationError.expectedStack(["settings"])) {
            _ = try await store.restore(from: data, using: codec, tabTopology: topology)
        }
        #expect(store.state == initial)
        #expect(store.revision == 0)
        let malformedHostStore = RouterStore(initialState: snapshot)
        let catalog = try RouterTabCatalog(R.routerTabs)
        #expect(throws: RouterMutationError.expectedStack(["settings"])) {
            _ = try RouterTabHost(store: malformedHostStore, catalog: catalog, allowingOrphanedBranches: true)
        }
    }

    @Test("Orphan containers are preserved but cannot be the host's selection")
    func orphanSelectionAndSubtree() throws {
        let nested = try RouterContainerState<R>(style: .custom("nested"), branches: [.init(id: "child")])
        let snapshot = try tabs([
            .init(id: "home"), .init(id: "settings"), .init(id: "legacy", node: .container(nested)),
        ], selection: "legacy")
        let catalog = try RouterTabCatalog(R.routerTabs)
        #expect(throws: RouterTabCatalogError.storeBranchesDoNotMatchCatalog) {
            _ = try RouterTabHost(store: .init(initialState: snapshot), catalog: catalog, allowingOrphanedBranches: true)
        }
        let reconciled = try RouterTabRestorationTopology(catalog: catalog).reconciling(snapshot)
        #expect(reconciled.node(at: ["legacy"]) == .container(nested))
        _ = try RouterTabHost(store: .init(initialState: reconciled), catalog: catalog, allowingOrphanedBranches: true)
    }

    @Test("Structural reports describe empty tab changes and decode older reports")
    func structuralReport() async throws {
        let snapshot = try tabs([.init(id: "home"), .init(id: "legacy")], selection: "legacy")
        let store = RouterStore(initialState: try tabs([.init(id: "home"), .init(id: "settings")]))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let result = try await store.restorePartially(
            from: codec.encode(snapshot), using: codec, validator: .init { _, _ in .keep },
            tabTopology: RouterTabRestorationTopology(of: R.self)
        )
        #expect(result.report.entries.isEmpty)
        #expect(result.report.topologyChanges == [
            .insertedScope("settings"), .reorderedScopes(["home", "settings", "legacy"]),
            .selectionChanged(from: "legacy", to: "home"),
        ])
        let encoded = try JSONEncoder().encode(result.report)
        #expect(try JSONDecoder().decode(RouterPartialRestorationReport.self, from: encoded) == result.report)
        let older = try JSONDecoder().decode(RouterPartialRestorationReport.self, from: Data(#"{"entries":[]}"#.utf8))
        #expect(older.topologyChanges.isEmpty)
        #expect(try JSONEncoder().encode(older) == Data(#"{"entries":[]}"#.utf8))
    }

    @Test("A stopped decoder cannot commit after a replacement driver finishes")
    func replacementDriverWhileDecoding() async throws {
        let finished = AsyncStream<Void>.makeStream()
        defer { finished.continuation.finish() }
        var configuration = RouterStoreConfiguration<R>()
        configuration.runtimeDependencies.didFinishRestorationWorker = { finished.continuation.yield(()) }
        let store = RouterStore(initialState: try tabs([.init(id: "home")]), configuration: configuration)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let first = RouterRestorationDriver(
            store: store, codec: codec,
            storage: TabSafetyStorage(data: try codec.encode(tabs([.init(id: "home", node: .stack(path: [.storedDetail]))]))),
            tabTopology: try RouterTabRestorationTopology(scopeIDs: ["home", "retired"])
        )
        let second = RouterRestorationDriver(
            store: store, codec: codec,
            storage: TabSafetyStorage(data: try codec.encode(tabs([.init(id: "home", node: .stack(path: [.newerDetail]))]))),
            tabTopology: try RouterTabRestorationTopology(of: R.self)
        )
        defer { first.stop(); second.stop() }
        let gate = TabSnapshotDecodeGate()
        TabSnapshotDecodeGate.active.withLock { $0 = gate }
        defer { gate.release(); TabSnapshotDecodeGate.active.withLock { $0 = nil } }
        let firstActivation = Task { try await first.activate() }
        defer { firstActivation.cancel() }
        guard await gate.waitUntilEntered() else { Issue.record("First decoder did not enter"); return }
        first.stop()
        guard case .restored = try await second.activate() else { Issue.record("Replacement did not restore"); return }
        let replacementState = store.state
        gate.release()
        do {
            _ = try await firstActivation.value
            Issue.record("Stopped activation should be cancelled")
        } catch is CancellationError { }
        let bothFinished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var count = 0
                for await _ in finished.stream { count += 1; if count == 2 { return true } }
                return false
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(bothFinished)
        #expect(store.state == replacementState)
        #expect(store.revision == 1)
        #expect(store.scope(at: ["retired"]).node == nil)
        #expect(store.scope(at: ["settings"]).node == .stack())
    }

    @Test("A rejected candidate still reports its structural changes without committing")
    func rejectedCandidateReport() async throws {
        let initial = try tabs([.init(id: "home")])
        var configuration = RouterStoreConfiguration<R>()
        configuration.policies = [.init(name: "deny") { _ in .reject("blocked") }]
        let store = RouterStore(initialState: initial, configuration: configuration)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let outcome = try await store.restorePartially(
            from: codec.encode(initial), using: codec, validator: .init { _, _ in .keep },
            tabTopology: RouterTabRestorationTopology(of: R.self)
        )
        guard case .rejected = outcome.transition else { Issue.record("Expected rejection"); return }
        #expect(outcome.report.topologyChanges.contains(.insertedScope("settings")))
        #expect(store.state == initial)
        #expect(store.revision == 0)
    }
}
