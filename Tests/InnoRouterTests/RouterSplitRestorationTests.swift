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
        let store = try RouterStore(initialState: initial)
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

    @Test("Exact restoration cannot silently change a declared split mapping", arguments: [false, true])
    func declaredMappingRequiresHostReplacement(threeColumn: Bool) async throws {
        let initial = try restoredSplitState(threeColumn: threeColumn, generation: "initial")
        let descriptor = try restoredSplitDescriptor(threeColumn: threeColumn, generation: "initial")
        let store = try RouterStore(initialState: initial, configuration: .init(hostDescriptor: descriptor))
        let codec = try RouterSnapshotCodec<RestoredSplitRoute>(currentVersion: 1)
        for swapped in [false, true] {
            let target = try restoredSplitState(threeColumn: threeColumn, swapped: swapped)
            let before = store.state
            let revision = store.revision
            guard case .rejected(_, _, _, .hostContract(let failure)) =
                try await store.restore(from: codec.encode(target), using: codec) else {
                Issue.record("Expected undeclared IDs or split roles to reject")
                return
            }
            #expect(failure.code == .splitMappingMismatch)
            #expect(store.state == before)
            #expect(store.revision == revision)

            // The owner deliberately replaces state and the independently
            // declared layout together, then constructs its new renderer.
            guard case .applied = await store.replaceHost(
                with: .init(state: target),
                descriptor: try restoredSplitDescriptor(threeColumn: threeColumn, swapped: swapped)
            ) else {
                Issue.record("Expected the explicit owner replacement to commit")
                return
            }
            if threeColumn {
                _ = try RouterThreeColumnSplitHost(
                    store: store, layout: restoredThreeColumnLayout(swapped: swapped),
                    sidebar: { EmptyView() }, content: { EmptyView() }, detail: { EmptyView() }
                )
            } else {
                _ = try RouterSplitHost(
                    store: store, layout: restoredTwoColumnLayout(swapped: swapped),
                    sidebar: { EmptyView() }, root: { EmptyView() }
                )
            }
            #expect(store.state == target)
            #expect(store.revision == revision + 1)
        }
    }

    #if canImport(AppKit)
    @Test("One mounted split host retains authority across compatible restoration", arguments: [false, true], [false, true])
    func mountedRestoration(threeColumn: Bool, startsAsSplit: Bool) async throws {
        let declaredInitial = try restoredSplitState(threeColumn: threeColumn)
        let initial: RouterState<RestoredSplitRoute> = startsAsSplit ? declaredInitial : .rootStack
        let descriptor: RouterHostDescriptor<RestoredSplitRoute> = startsAsSplit
            ? try restoredSplitDescriptor(threeColumn: threeColumn) : .init(root: .stack)
        let store = try RouterStore(initialState: initial, configuration: .init(hostDescriptor: descriptor))
        let codec = try RouterSnapshotCodec<RestoredSplitRoute>(currentVersion: 1)
        let recorder = RestoredSplitRecorder()
        if !startsAsSplit {
            do {
                _ = try restoredSplitView(store: store, threeColumn: threeColumn, recorder: recorder)
                Issue.record("A split host must reject the declared stack before mounting")
            } catch let failure as RouterHostValidationFailure {
                #expect(failure.code == .rendererMismatch)
            }
            #expect(store.state == initial)
            #expect(store.revision == 0)
            guard case .applied = await store.replaceHost(
                with: .init(state: declaredInitial),
                descriptor: try restoredSplitDescriptor(threeColumn: threeColumn)
            ) else {
                Issue.record("Expected explicit setup to replace the root host")
                return
            }
        }
        let view = try restoredSplitView(store: store, threeColumn: threeColumn, recorder: recorder)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1400, height: 900))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await recorder.waitFor(expectedColumns(in: declaredInitial))
        let columns: [RouterSplitColumn] = threeColumn ? [.sidebar, .content, .detail] : [.sidebar, .detail]

        // Retain this exact rootView across distinct compatible path restores.
        // A renderer cannot silently acquire new role mappings.
        for generation in [1, 2] {
            var target = declaredInitial
            let split = try #require(rootSplitState(of: target))
            for column in columns {
                let id = try #require(split.scopeID(for: column))
                target = try RouterReducer.reduce(
                    .push(.marker("restored-\(generation)")).inScope(id), from: target
                )
            }
            guard case .applied = try await store.restore(from: codec.encode(target), using: codec) else {
                Issue.record("Expected compatible split restoration to commit")
                return
            }
            #expect(store.state == target)
            try await recorder.waitFor(expectedColumns(in: target))
            for column in columns {
                let observed = try #require(recorder.columns[column])
                let id = try #require(split.scopeID(for: column))
                guard case .applied = await observed.actions.perform(.push(.marker("from-" + column.rawValue))) else {
                    Issue.record("Restored column navigation must retain its declared scope")
                    return
                }
                #expect(store.state.node(at: [id]) == .stack(path: [
                    .marker(column.rawValue), .marker("restored-\(generation)"),
                    .marker("from-" + column.rawValue),
                ]))
            }
        }

        let branchIDs: [RouterScopeID] = threeColumn
            ? ["restored-a", "restored-b", "restored-c"] : ["restored-a", "restored-c"]
        let tabs = try RouterState<RestoredSplitRoute>(root: .container(.init(
            style: .tabs, selection: "restored-a",
            branches: branchIDs.map { .init(id: $0, node: .stack(path: [.marker("hidden")])) }
        )))
        let before = store.state
        let revision = store.revision
        guard case .rejected(_, _, _, .hostContract(let failure)) =
            try await store.restore(from: codec.encode(tabs), using: codec) else {
            Issue.record("Expected incompatible restoration to reject before commit")
            return
        }
        #expect(failure.code == .kindMismatch)
        #expect(store.state == before)
        #expect(store.revision == revision)
        try await recorder.waitFor(expectedColumns(in: before))

        // The same mounted host remains usable after rejection; no fake
        // unresolved column and no replacement renderer are required.
        guard case .applied = try await store.restore(from: codec.encode(declaredInitial), using: codec) else {
            Issue.record("Expected compatible recovery to commit")
            return
        }
        try await recorder.waitFor(expectedColumns(in: declaredInitial))
    }
    #endif
}

private func restoredTwoColumnLayout(
    generation: String = "restored", swapped: Bool = false
) throws -> RouterTwoColumnSplitLayout {
    try .init(
        sidebarScopeID: .init("\(generation)-" + (swapped ? "c" : "a")),
        detailScopeID: .init("\(generation)-" + (swapped ? "a" : "c"))
    )
}

private func restoredThreeColumnLayout(
    generation: String = "restored", swapped: Bool = false
) throws -> RouterThreeColumnSplitLayout {
    try .init(
        sidebarScopeID: .init("\(generation)-" + (swapped ? "c" : "a")),
        contentScopeID: .init("\(generation)-b"),
        detailScopeID: .init("\(generation)-" + (swapped ? "a" : "c"))
    )
}

private func restoredSplitDescriptor(
    threeColumn: Bool, generation: String = "restored", swapped: Bool = false
) throws -> RouterHostDescriptor<RestoredSplitRoute> {
    let shape = threeColumn
        ? try restoredThreeColumnLayout(generation: generation, swapped: swapped).hostShape
        : try restoredTwoColumnLayout(generation: generation, swapped: swapped).hostShape
    return .init(root: shape)
}

#if canImport(AppKit)
@MainActor
private func restoredSplitView(
    store: RouterStore<RestoredSplitRoute>, threeColumn: Bool, recorder: RestoredSplitRecorder
) throws -> AnyView {
    if threeColumn {
        return AnyView(try RouterThreeColumnSplitHost(
            store: store, layout: restoredThreeColumnLayout(),
            sidebar: { RestoredSplitProbe(column: .sidebar, recorder: recorder) },
            content: { RestoredSplitProbe(column: .content, recorder: recorder) },
            detail: { RestoredSplitProbe(column: .detail, recorder: recorder) }
        ))
    }
    return AnyView(try RouterSplitHost(
        store: store, layout: restoredTwoColumnLayout(),
        sidebar: { RestoredSplitProbe(column: .sidebar, recorder: recorder) },
        root: { RestoredSplitProbe(column: .detail, recorder: recorder) }
    ))
}
#endif

#if canImport(AppKit)
@MainActor
private func expectedColumns(
    in state: RouterState<RestoredSplitRoute>
) throws -> [RouterSplitColumn: RestoredSplitRecorder.Expected] {
    let split = try #require(rootSplitState(of: state))
    let columns: [RouterSplitColumn] = split.content == nil ? [.sidebar, .detail] : [.sidebar, .content, .detail]
    return try Dictionary(uniqueKeysWithValues: columns.map { column in
        let id = try #require(split.scopeID(for: column))
        guard case .stack(let stack) = state.node(at: [id]) else {
            throw RouterMutationError.expectedStack([id])
        }
        return (column, RestoredSplitRecorder.Expected(
            scope: RouterScopePath([.branch(id)]), path: stack.path
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
