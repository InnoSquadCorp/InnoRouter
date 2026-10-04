import Foundation
import Observation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if !os(watchOS)
private enum RestoredSplitRoute: Codable, DestinationRoute {
    case marker(String)

    static func destination(for route: Self) -> some View {
        Text(String(describing: route))
    }
}

private func restoredSplitState(
    threeColumn: Bool,
    generation: String = "restored",
    swapped: Bool = false
) throws -> RouterState<RestoredSplitRoute> {
    let first = RouterScopeID("\(generation)-a")
    let last = RouterScopeID("\(generation)-c")
    let split = try RouterSplitState(
        sidebar: swapped ? last : first,
        content: threeColumn ? RouterScopeID("\(generation)-b") : nil,
        detail: swapped ? first : last,
        visibility: .all
    )
    let columns: [RouterSplitColumn] = threeColumn ? [.sidebar, .content, .detail] : [.sidebar, .detail]
    let branches = try columns.map { column in
        let id = try #require(split.scopeID(for: column))
        return RouterBranch<RestoredSplitRoute>(
            id: id,
            node: .stack(path: [.marker(column.rawValue)])
        )
    }
    return try RouterState(root: .container(.init(
        style: .split,
        selection: split.detail,
        branches: branches,
        split: split
    )))
}

@Suite("Split host exact restoration", .tags(.unit), .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterSplitRestorationTests {
    @Test("Default links follow new column IDs and reassigned roles", arguments: [false, true])
    func currentDetailLink(threeColumn: Bool) async throws {
        let initial = try restoredSplitState(threeColumn: threeColumn, generation: "initial")
        let store = RouterStore(initialState: initial)
        let codec = try RouterSnapshotCodec<RestoredSplitRoute>(currentVersion: 1)
        for swapped in [false, true] {
            let target = try restoredSplitState(threeColumn: threeColumn, swapped: swapped)
            guard case .applied = try await store.restore(from: codec.encode(target), using: codec) else {
                Issue.record("Expected exact split restoration to commit")
                return
            }
            #expect(store.state == target)

            // A URL can arrive before the mounted host renders again. Its
            // target must come from this exact state, not any captured IDs.
            let plan = try splitHostLinkPlan(.marker("link"), store.state)
            let split = try #require(rootSplitState(of: target))
            let expected = try RouterReducer.reduce(
                .push(RestoredSplitRoute.marker("link")).inScope(split.detail),
                from: target
            )
            #expect(plan.state == expected)
            #expect(plan.state.node(at: [split.sidebar]) == .stack(path: [.marker("sidebar")]))
            if let content = split.content {
                #expect(plan.state.node(at: [content]) == .stack(path: [.marker("content")]))
            }
        }
    }

    @Test("Split links still reject other root shapes and presented detail stacks")
    func linkRejectionControls() throws {
        let branches: [RouterBranch<RestoredSplitRoute>] = [
            .init(id: "restored-a"), .init(id: "restored-c"),
        ]
        let tabs = try RouterState<RestoredSplitRoute>(root: .container(.init(
            style: .tabs, selection: "restored-c", branches: branches
        )))
        let custom = try RouterState<RestoredSplitRoute>(root: .container(.init(
            style: .custom("wizard"), selection: "restored-c", branches: branches
        )))
        for state in [RouterState<RestoredSplitRoute>.rootStack, tabs, custom] {
            #expect(throws: RouterMutationError.incompatibleNavigationTopology(.root)) {
                try splitHostLinkPlan(.marker("link"), state)
            }
        }

        let presented = try RouterReducer.reduce(
            .present(.init(route: RestoredSplitRoute.marker("modal"), style: .sheet)).inScope("restored-c"),
            from: restoredSplitState(threeColumn: false)
        )
        #expect(throws: RouterMutationError.blockedByPresentation(["restored-c"])) {
            try splitHostLinkPlan(.marker("link"), presented)
        }
    }

    @Test("Each host body observes split mapping even when the root style is unchanged", arguments: [false, true])
    func bodyObservesCurrentMapping(threeColumn: Bool) async throws {
        let initial = try restoredSplitState(threeColumn: threeColumn, generation: "initial")
        let store = RouterStore(initialState: initial)
        let target = try restoredSplitState(threeColumn: threeColumn)
        if threeColumn {
            try await requireMappingObservation(
                RouterThreeColumnSplitHost(
                    store: store,
                    sidebar: { EmptyView() },
                    content: { EmptyView() },
                    detail: { EmptyView() }
                ),
                store: store,
                replacement: target
            )
        } else {
            try await requireMappingObservation(
                RouterSplitHost(
                    store: store,
                    sidebar: { EmptyView() },
                    root: { EmptyView() }
                ),
                store: store,
                replacement: target
            )
        }
    }

    #if canImport(AppKit)
    @Test("One mounted split host follows restoration without reconstructing its root view", arguments: [false, true], [false, true])
    func mountedRestoration(threeColumn: Bool, startsAsSplit: Bool) async throws {
        let initial: RouterState<RestoredSplitRoute> = startsAsSplit
            ? try restoredSplitState(threeColumn: threeColumn, generation: "initial")
            : .rootStack
        let store = RouterStore(initialState: initial)
        let codec = try RouterSnapshotCodec<RestoredSplitRoute>(currentVersion: 1)
        let recorder = RestoredSplitRecorder()
        let view: AnyView
        if threeColumn {
            view = AnyView(RouterThreeColumnSplitHost(
                store: store,
                sidebar: { RestoredSplitProbe(column: .sidebar, recorder: recorder) },
                content: { RestoredSplitProbe(column: .content, recorder: recorder) },
                detail: { RestoredSplitProbe(column: .detail, recorder: recorder) }
            ))
        } else {
            view = AnyView(RouterSplitHost(
                store: store,
                sidebar: { RestoredSplitProbe(column: .sidebar, recorder: recorder) },
                root: { RestoredSplitProbe(column: .detail, recorder: recorder) }
            ))
        }
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        if startsAsSplit {
            try await recorder.waitFor(expectedColumns(in: initial))
        } else {
            try await recorder.waitFor([.detail: .init(scope: .unresolvable, path: [])])
        }

        let columns: [RouterSplitColumn] = threeColumn ? [.sidebar, .content, .detail] : [.sidebar, .detail]
        // Keep this exact rootView mounted throughout. Reconstructing a host
        // would refresh an initializer cache and conceal the regression.
        // First replace all IDs; then swap semantic roles with IDs unchanged.
        for swapped in [false, true] {
            let target = try restoredSplitState(threeColumn: threeColumn, swapped: swapped)
            guard case .applied = try await store.restore(from: codec.encode(target), using: codec) else {
                Issue.record("Expected exact split restoration to commit")
                return
            }
            #expect(store.state == target)
            let split = try #require(rootSplitState(of: target))
            try await recorder.waitFor(expectedColumns(in: target))
            for column in columns {
                let observed = try #require(recorder.columns[column])
                let id = try #require(split.scopeID(for: column))
                let outcome = await observed.actions.perform(.push(.marker("from-" + column.rawValue)))
                guard case .applied = outcome else {
                    Issue.record("Restored column navigation must use its current scope")
                    return
                }
                #expect(store.state.node(at: [id]) == .stack(path: [
                    .marker(column.rawValue), .marker("from-" + column.rawValue),
                ]))
            }
        }

        // Same-named branches of a different root still cannot be rendered
        // or written through the mounted split host.
        let branchIDs: [RouterScopeID] = threeColumn
            ? ["restored-a", "restored-b", "restored-c"] : ["restored-a", "restored-c"]
        let tabs = try RouterState<RestoredSplitRoute>(root: .container(.init(
            style: .tabs,
            selection: "restored-a",
            branches: branchIDs.map { .init(id: $0, node: .stack(path: [.marker("hidden")])) }
        )))
        guard case .applied = try await store.restore(from: codec.encode(tabs), using: codec) else {
            Issue.record("Expected non-split restoration to commit")
            return
        }
        let revision = store.revision
        let unresolved = Dictionary(uniqueKeysWithValues: columns.map {
            ($0, RestoredSplitRecorder.Expected(scope: .unresolvable, path: []))
        })
        try await recorder.waitFor(unresolved)
        for column in columns {
            let observed = try #require(recorder.columns[column])
            guard case .rejected = await observed.actions.perform(.push(.marker("blocked"))) else {
                Issue.record("Non-split column navigation must be rejected")
                return
            }
        }
        #expect(store.state == tabs)
        #expect(store.revision == revision)

        // Recovery from that incompatible shape must use yet another set of
        // current IDs, without recreating the same mounted host.
        let recovered = try restoredSplitState(threeColumn: threeColumn, generation: "recovered")
        guard case .applied = try await store.restore(from: codec.encode(recovered), using: codec) else {
            Issue.record("Expected split recovery to commit")
            return
        }
        try await recorder.waitFor(expectedColumns(in: recovered))
        #expect(store.state == recovered)
    }
    #endif
}

@MainActor
private func requireMappingObservation<V: View>(
    _ host: V,
    store: RouterStore<RestoredSplitRoute>,
    replacement: RouterState<RestoredSplitRoute>
) async throws {
    let initial = try #require(rootSplitState(of: store.state))
    // Retain and warm every scope before observation. Otherwise creating a
    // previously uncached scope reads store.state and falsely hides the bug.
    let scopes = [store.scope()] + [initial.sidebar, initial.content, initial.detail]
        .compactMap { $0 }
        .map { store.scope(at: [$0]) }
    defer { withExtendedLifetime(scopes) {} }
    let (changes, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    withObservationTracking {
        _ = host.body
    } onChange: {
        continuation.yield(())
    }
    let codec = try RouterSnapshotCodec<RestoredSplitRoute>(currentVersion: 1)
    guard case .applied = try await store.restore(from: codec.encode(replacement), using: codec) else {
        Issue.record("Expected a split mapping-only restore to commit")
        return
    }
    #expect(store.state == replacement)
    #expect(scopes[0].reconciliationRevision == 0)
    _ = try await firstElement(from: changes, what: "split host mapping invalidation")
}

#if canImport(AppKit)
@MainActor
private func expectedColumns(
    in state: RouterState<RestoredSplitRoute>
) throws -> [RouterSplitColumn: RestoredSplitRecorder.Expected] {
    let split = try #require(rootSplitState(of: state))
    let columns: [RouterSplitColumn] = split.content == nil ? [.sidebar, .detail] : [.sidebar, .content, .detail]
    return try Dictionary(uniqueKeysWithValues: columns.map { column in
        let id = try #require(split.scopeID(for: column))
        return (column, RestoredSplitRecorder.Expected(
            scope: RouterScopePath([.branch(id)]), path: [.marker(column.rawValue)]
        ))
    })
}

@MainActor
private final class RestoredSplitRecorder {
    struct Expected: Equatable {
        let scope: RouterScopePath?
        let path: [RestoredSplitRoute]
    }

    struct Column {
        let value: Expected
        let actions: RouterActions<RestoredSplitRoute>
    }

    var columns: [RouterSplitColumn: Column] = [:]

    func record(_ column: RouterSplitColumn, value: Expected, actions: RouterActions<RestoredSplitRoute>) {
        columns[column] = Column(value: value, actions: actions)
    }

    func waitFor(_ expected: [RouterSplitColumn: Expected]) async throws {
        try await waitUntil("mounted split column scopes and paths", timeout: .seconds(10)) {
            expected.allSatisfy { self.columns[$0.key]?.value == $0.value }
        }
    }
}

@MainActor
private struct RestoredSplitProbe: View {
    @EnvironmentRouterState(RestoredSplitRoute.self) private var state
    @EnvironmentRouter(RestoredSplitRoute.self) private var actions
    let column: RouterSplitColumn
    let recorder: RestoredSplitRecorder

    var body: some View {
        RestoredSplitCapture(
            column: column,
            value: .init(scope: state.scopePath, path: state.path),
            actions: actions,
            recorder: recorder
        )
    }
}

@MainActor
private struct RestoredSplitCapture: NSViewRepresentable {
    let column: RouterSplitColumn
    let value: RestoredSplitRecorder.Expected
    let actions: RouterActions<RestoredSplitRoute>
    let recorder: RestoredSplitRecorder

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        recorder.record(column, value: value, actions: actions)
    }
}
#endif
#endif
