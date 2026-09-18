import Foundation
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

/// Regression coverage for the restoration-boundary remediation plan
/// (`Docs/2026-09-18-restoration-boundary-remediation-plan.ko.md`).
///
/// R1 and R2 describe restoration reconciling a decoded snapshot against
/// topology that the caller never supplied. Every test here states the
/// behavior a caller can observe, not the internal mechanism.
@Suite("RouterRestorationBoundary")
struct RouterRestorationBoundaryRegressionTests {
    private enum BoundaryRoute: String, Route, Codable {
        case home
        case detail
        case legacy
        case recovered
    }

    private static let sharedPresentationID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000011"
    )!

    private static func tabs(
        selection: RouterScopeID,
        _ branches: [RouterBranch<BoundaryRoute>],
        badges: [RouterScopeID: Int] = [:]
    ) throws -> RouterState<BoundaryRoute> {
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

    private static func branchIDs(
        _ state: RouterState<BoundaryRoute>
    ) -> [RouterScopeID]? {
        guard case .container(let container) = state.root else { return nil }
        return container.branches.map(\.id)
    }

    private static func presentationIDs(in node: RouterNode<BoundaryRoute>) -> [UUID] {
        switch node {
        case .stack(let stack):
            stack.presentation.map { [$0.id] } ?? []
        case .container(let container):
            container.branches.flatMap { presentationIDs(in: $0.node) }
        }
    }

    private static func routes(in node: RouterNode<BoundaryRoute>) -> [BoundaryRoute] {
        switch node {
        case .stack(let stack):
            stack.path + (stack.presentation.map { [$0.route] } ?? [])
        case .container(let container):
            container.branches.flatMap { routes(in: $0.node) }
        }
    }

    /// Records every route the application was asked to validate.
    @MainActor
    private final class ValidationLog {
        private(set) var observed: [BoundaryRoute] = []
        func record(_ route: BoundaryRoute) { observed.append(route) }
    }

    // MARK: - R1: initial payload must not enter a restored state

    @Test("A tab missing from a snapshot does not reintroduce unvalidated routes")
    @MainActor
    func missingTabDoesNotReintroduceUnvalidatedRoutes() async throws {
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack()),
                    .init(id: "settings", node: .stack(path: [.legacy])),
                ]
            )
        )
        let codec = try RouterSnapshotCodec<BoundaryRoute>(currentVersion: 1)
        let data = try codec.encode(
            try Self.tabs(
                selection: "home",
                [.init(id: "home", node: .stack(path: [.detail]))]
            )
        )
        let log = ValidationLog()

        let outcome = try await store.restorePartially(
            from: data,
            using: codec,
            validator: .init { route, _ in
                log.record(route)
                return .keep
            }
        )

        guard case .applied(_, _, let restored, _) = outcome.transition else {
            Issue.record("Expected one applied partial-restoration transition")
            return
        }
        // `.legacy` exists only in the store's initial state. It was never
        // written to the snapshot, so the application never validated it and
        // it must not appear in the applied result.
        let applied = Self.routes(in: restored.root)
        #expect(log.observed == [.detail])
        #expect(applied == [.detail])
        for route in applied where !log.observed.contains(route) {
            Issue.record("applied an unvalidated route: \(route)")
        }
    }

    @Test("A tab missing from a snapshot does not retain its initial presentation")
    @MainActor
    func missingTabDoesNotRetainInitialPresentations() async throws {
        let initialPresentation = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let snapshotPresentation = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack()),
                    .init(
                        id: "settings",
                        node: .stack(
                            presentation: .init(
                                id: initialPresentation,
                                route: .detail,
                                style: .sheet
                            )
                        )
                    ),
                ]
            )
        )
        let codec = try RouterSnapshotCodec<BoundaryRoute>(currentVersion: 1)
        let data = try codec.encode(
            try Self.tabs(
                selection: "home",
                [
                    .init(
                        id: "home",
                        node: .stack(
                            presentation: .init(
                                id: snapshotPresentation,
                                route: .detail,
                                style: .sheet
                            )
                        )
                    ),
                ]
            )
        )

        let outcome = try await store.restore(from: data, using: codec)

        guard case .applied(_, _, let restored, _) = outcome else {
            Issue.record("Expected a valid snapshot to restore, got \(outcome)")
            return
        }
        #expect(Self.branchIDs(restored) == ["home"])
        #expect(
            Self.presentationIDs(in: restored.root) == [snapshotPresentation],
            "restoration kept a presentation the snapshot never contained"
        )
    }

    // MARK: - R2: store-creation topology must not constrain later restores

    @Test("Exact restore round-trips a root that changed from tabs to a stack")
    @MainActor
    func exactRestoreRoundTripsAfterTabsBecomeStack() async throws {
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack()),
                    .init(id: "settings", node: .stack()),
                ]
            )
        )
        let target = try RouterState<BoundaryRoute>(root: .stack(path: [.home]))
        guard case .applied = await store.perform(.apply(RouterPlan(state: target))) else {
            Issue.record("Expected the application's own plan to apply")
            return
        }

        let codec = try RouterSnapshotCodec<BoundaryRoute>(currentVersion: 1)
        let data = try codec.encode(store.state)
        let outcome = try await store.restore(from: data, using: codec)

        switch outcome {
        case .applied(_, _, let restored, _):
            #expect(restored == target)
        case .unchanged(_, let state, _):
            #expect(state == target)
        default:
            Issue.record("Expected a self-written snapshot to restore, got \(outcome)")
        }
    }

    @Test("Exact restore round-trips a catalog that removed a tab")
    @MainActor
    func exactRestoreRoundTripsAfterTabRemoval() async throws {
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack()),
                    .init(id: "settings", node: .stack()),
                ]
            )
        )
        let target = try Self.tabs(
            selection: "home",
            [.init(id: "home", node: .stack(path: [.detail]))]
        )
        guard case .applied = await store.perform(.apply(RouterPlan(state: target))) else {
            Issue.record("Expected the application's own plan to apply")
            return
        }

        let codec = try RouterSnapshotCodec<BoundaryRoute>(currentVersion: 1)
        let data = try codec.encode(store.state)
        let outcome = try await store.restore(from: data, using: codec)

        switch outcome {
        case .applied(_, _, let restored, _):
            #expect(Self.branchIDs(restored) == ["home"])
        case .unchanged(_, let state, _):
            #expect(Self.branchIDs(state) == ["home"])
        default:
            Issue.record("Expected a self-written snapshot to restore, got \(outcome)")
        }
    }

    @Test("An application recovery fallback is applied exactly as returned")
    @MainActor
    func recoveryFallbackIsAppliedWithoutReconciliation() async throws {
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack()),
                    .init(id: "settings", node: .stack()),
                ]
            )
        )
        let codec = try RouterSnapshotCodec<BoundaryRoute>(currentVersion: 1)
        let fallback = try RouterState<BoundaryRoute>(root: .stack(path: [.recovered]))

        let outcome = try await store.restore(
            from: Data("not a snapshot".utf8),
            using: codec,
            recovery: .use { _ in fallback }
        )

        guard case .recovered = outcome.decoding else {
            Issue.record("Expected the corrupt payload to reach the recovery policy")
            return
        }
        switch outcome.transition {
        case .applied(_, _, let restored, _):
            #expect(restored == fallback)
        case .unchanged(_, let state, _):
            #expect(state == fallback)
        default:
            Issue.record("Expected the app's fallback to apply, got \(outcome.transition)")
        }
    }

    // MARK: - Control: the capability this work must still deliver

    @Test("A tab added since the snapshot was written becomes navigable")
    @MainActor
    func tabAddedSinceSnapshotBecomesNavigable() async throws {
        let store = RouterStore(
            initialState: try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack()),
                    .init(id: "settings", node: .stack()),
                    .init(id: "profile", node: .stack()),
                ]
            )
        )
        let codec = try RouterSnapshotCodec<BoundaryRoute>(currentVersion: 1)
        let data = try codec.encode(
            try Self.tabs(
                selection: "home",
                [
                    .init(id: "home", node: .stack()),
                    .init(id: "settings", node: .stack(path: [.detail])),
                ]
            )
        )

        _ = try await store.restore(from: data, using: codec)

        // Withheld until RBR-T04 lands the explicit-topology restore. The
        // reverted reconciler delivered this only by reading topology the
        // caller never supplied, which is what R1 and R2 above reject.
        await withKnownIssue("RBR-T04: explicit tab topology is not implemented yet") {
            #expect(Self.branchIDs(store.state)?.contains("profile") == true)
            guard case .applied = await store.perform(
                .push(.detail).inScope("profile")
            ) else {
                Issue.record("Expected the newly added tab to accept navigation")
                return
            }
        }
    }
}
