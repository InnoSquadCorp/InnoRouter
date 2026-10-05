import Foundation
import Testing

import InnoRouterCore
#if canImport(InnoRouterRestorationContracts)
@testable import InnoRouterRestorationContracts
#else
@testable import InnoRouterSwiftUI
#endif

private enum TopologyRoute: Int, Route, Codable { case home, detail, modal, window, space }

@Suite("Production restoration topology contracts", .serialized)
struct RouterTabRestorationTopologyContractTests {
    @Test("Empty and duplicate catalog-free topology inputs fail closed")
    func invalidTopologyInputs() throws {
        #expect(throws: RouterTabRestorationError.emptyTopology) { try RouterTabRestorationTopology(scopeIDs: []) }
        #expect(throws: RouterTabRestorationError.duplicateScopeID("main")) {
            try RouterTabRestorationTopology(scopeIDs: ["main", "other", "main"])
        }
    }

    @Test("Matching topology is an exact-state positive control")
    func unchangedTopologyPositiveControl() throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["main", "other"])
        let source = try RouterState<TopologyRoute>(root: .container(try .init(
            style: .tabs, selection: "other", branches: [
                .init(id: "main", node: .stack(path: [.home])),
                .init(id: "other", node: .stack(path: [.detail])),
            ], badges: ["other": 2]
        )))
        let result = try topology.reconciling(source)
        #expect(result == source)
        #expect(topology.changes(from: source, to: result).isEmpty)
        #expect(topology.fallbackSelection == "main")
    }

    @Test("Reorder and insertion preserve orphan order, content, badges and independent scenes")
    func reorderOrphanPreservationAndSelectionFallback() throws {
        let presentation = RouterPresentation<TopologyRoute>(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000711")!,
            route: .modal, style: .sheet, node: .stack(path: [.detail])
        )
        let orphanTree = try RouterContainerState<TopologyRoute>(style: .custom("old-flow"), branches: [
            .init(id: "nested", node: .stack(path: [.detail])),
        ])
        let source = try RouterState<TopologyRoute>(
            root: .container(try .init(style: .tabs, selection: "orphan-b", branches: [
                .init(id: "orphan-a", node: .container(orphanTree)),
                .init(id: "main", node: .stack(path: [.home], presentation: presentation)),
                .init(id: "orphan-b", node: .stack(path: [.detail])),
                .init(id: "other", node: .stack(path: [.detail])),
            ], badges: ["main": 3, "orphan-a": 7, "orphan-b": 9])),
            windows: [.init(route: .window, node: .stack(path: [.detail]))],
            immersiveSpace: .init(id: "space", route: .space, node: .stack(path: [.home]))
        )
        let topology = try RouterTabRestorationTopology(scopeIDs: ["other", "added", "main"])
        let result = try topology.reconciling(source)
        guard case .container(let before) = source.root, case .container(let after) = result.root else {
            Issue.record("Expected tab roots"); return
        }
        #expect(after.branches.map(\.id) == ["other", "added", "main", "orphan-a", "orphan-b"])
        #expect(after.branches[0] == before.branches[3])
        #expect(after.branches[1] == .init(id: "added", node: .stack()))
        #expect(after.branches[2] == before.branches[1])
        #expect(Array(after.branches.suffix(2)) == [before.branches[0], before.branches[2]])
        #expect(after.badges == before.badges)
        #expect(after.selection == "other")
        #expect(result.windows == source.windows && result.immersiveSpace == source.immersiveSpace)
        #expect(topology.changes(from: source, to: result) == [
            .insertedScope("added"),
            .reorderedScopes(["other", "added", "main", "orphan-a", "orphan-b"]),
            .selectionChanged(from: "orphan-b", to: "other"),
        ])
    }

    @Test("A still-current selection survives topology reorder")
    func validSelectionSurvivesReorder() throws {
        let source = try RouterState<TopologyRoute>(root: .container(try .init(
            style: .tabs, selection: "main", branches: [.init(id: "main"), .init(id: "other")]
        )))
        let topology = try RouterTabRestorationTopology(scopeIDs: ["other", "main"])
        let result = try topology.reconciling(source)
        guard case .container(let tabs) = result.root else { Issue.record("Expected tabs"); return }
        #expect(tabs.selection == "main")
        #expect(topology.changes(from: source, to: result) == [.reorderedScopes(["other", "main"])])
    }

    @Test("A non-tabs root is rejected rather than silently reshaped")
    func mismatchedRootFailsClosed() throws {
        let topology = try RouterTabRestorationTopology(scopeIDs: ["main"])
        let roots: [RouterNode<TopologyRoute>] = [
            .stack(path: [.home]),
            .container(try .init(style: .custom("root"), branches: [.init(id: "main")])),
        ]
        for root in roots {
            let source = try RouterState(root: root)
            #expect(throws: RouterTabRestorationError.rootIsNotTabs) { try topology.reconciling(source) }
            #expect(source.root == root)
        }
    }

    @Test("A named current tab must be a stack even when an orphan container is preserved")
    func namedContainerFailsClosed() throws {
        let nested = try RouterContainerState<TopologyRoute>(style: .custom("nested"), branches: [.init(id: "child")])
        let source = try RouterState<TopologyRoute>(root: .container(try .init(
            style: .tabs, selection: "main", branches: [.init(id: "main", node: .container(nested))]
        )))
        let named = try RouterTabRestorationTopology(scopeIDs: ["main"])
        #expect(throws: RouterMutationError.expectedStack(["main"])) { try named.reconciling(source) }
        let orphan = try RouterTabRestorationTopology(scopeIDs: ["replacement"])
        let result = try orphan.reconciling(source)
        #expect(result.node(at: ["main"]) == .container(nested))
    }

    @Test("Topology reconciliation followed by planning validates preserved and orphan routes only")
    @MainActor
    func reconciliationBeforePlanning() async throws {
        let source = try RouterState<TopologyRoute>(root: .container(try .init(
            style: .tabs, selection: "orphan", branches: [
                .init(id: "main", node: .stack(path: [.home])),
                .init(id: "orphan", node: .stack(path: [.detail])),
            ]
        )))
        let topology = try RouterTabRestorationTopology(scopeIDs: ["added", "main"])
        let reconciled = try topology.reconciling(source)
        var locations: [RouterRestorationRouteLocation] = []
        let planned = try await preparePartialRestoration(reconciled, validator: .init { _, location in
            locations.append(location)
            return .keep
        }, operations: .init(maximumCount: 8), timeout: nil, sleep: { _ in })
        #expect(planned.0 == reconciled)
        #expect(locations == [
            .init(scope: ["main"], role: .path, index: 0),
            .init(scope: ["orphan"], role: .path, index: 0),
        ])
        #expect(topology.changes(from: source, to: planned.0) == [
            .insertedScope("added"), .reorderedScopes(["added", "main", "orphan"]),
            .selectionChanged(from: "orphan", to: "added"),
        ])
        // This composes real pure functions. It does not execute Store.apply.
    }
}
