#if canImport(AppKit)
import AppKit
#endif
import Observation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

#if !os(watchOS)
private enum RouterSplitHostRoute: DestinationRoute {
    case detail(id: String)
    case modal

    static func destination(for route: Self) -> some View {
        switch route {
        case .detail(let id): Text("Detail \(id)")
        case .modal: Text("Modal")
        }
    }
}

@MainActor
private final class RouterSplitHostInvocationGate {
    private var didRun = false

    func run(_ action: () -> Void) {
        guard !didRun else { return }
        didRun = true
        action()
    }
}

@MainActor
private struct RouterSplitHostProbe: View {
    @EnvironmentRouter(RouterSplitHostRoute.self) private var router
    let gate: RouterSplitHostInvocationGate

    var body: some View {
        Color.clear.onAppear {
            gate.run {
                router.go(.detail(id: "visible"))
                router.sheet(.modal)
                router.go(.detail(id: "blocked"))
            }
        }
    }
}

@MainActor
private struct RouterSplitReplacementProbe: View {
    @EnvironmentRouterState(RouterSplitHostRoute.self) private var router
    let generation: Int
    let observations: RouterSplitReplacementObservations

    var body: some View {
#if canImport(AppKit)
        RouterSplitStateCapture(
            generation: generation,
            path: router.path,
            observations: observations
        )
#else
        Color.clear
#endif
    }
}

@MainActor
private final class RouterSplitReplacementObservations {
    var paths: [Int: [RouterSplitHostRoute]] = [:]
}

#if canImport(AppKit)
private struct RouterSplitStateCapture: NSViewRepresentable {
    let generation: Int
    let path: [RouterSplitHostRoute]
    let observations: RouterSplitReplacementObservations

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        observations.paths[generation] = path
    }
}
#endif

@MainActor
@Observable
private final class RouterSplitEventRecorder {
    var events: [RouterEvent<RouterSplitHostRoute>] = []
}

@Suite("RouterSplitHost", .tags(.unit))
@MainActor
struct RouterSplitHostTests {
    @Test("Macro-first split host owns a split container and detail scope")
    func construction() {
        let host = RouterSplitHost(
            RouterSplitHostRoute.self,
            initialPath: [.detail(id: "initial")]
        ) {
            Text("Sidebar")
        } root: {
            Text("Select a route")
        }

        _ = host.body
    }

    @Test("Typed split layouts reject invalid scope topology before host construction")
    func validatedLayout() {
        #expect(throws: RouterStateValidationError.duplicateSplitColumnScope) {
            try RouterTwoColumnSplitLayout(
                sidebarScopeID: "duplicate",
                detailScopeID: "duplicate"
            )
        }
        #expect(throws: RouterStateValidationError.unavailableSplitColumn(.content)) {
            try RouterTwoColumnSplitLayout(preferredCompactColumn: .content)
        }
        #expect(throws: RouterStateValidationError.duplicateSplitColumnScope) {
            try RouterThreeColumnSplitLayout(
                sidebarScopeID: "sidebar",
                contentScopeID: "detail",
                detailScopeID: "detail"
            )
        }
    }

    @Test("Split descendants share the canonical stack and presentation invariant")
    func unifiedAuthority() async throws {
        let recorder = RouterSplitEventRecorder()
        let splitState = try RouterSplitState(
            sidebar: "sidebar",
            detail: "detail"
        )
        let split = try RouterContainerState<RouterSplitHostRoute>(
            style: .split,
            selection: "detail",
            branches: [
                RouterBranch(id: "sidebar"),
                RouterBranch(id: "detail"),
            ],
            split: splitState
        )
        let store = RouterStore<RouterSplitHostRoute>(
            initialState: try RouterState(root: .container(split)),
            configuration: .init { recorder.events.append($0) }
        )
        let gate = RouterSplitHostInvocationGate()
        let host = RouterSplitHost(
            store: store,
            sidebar: { Text("Sidebar") },
            root: { RouterSplitHostProbe(gate: gate) }
        )

        _ = try renderRouterSplitHost(host)
        for _ in 0..<6 { await Task.yield() }

        guard case .container(let container) = store.state.root,
              container.style == .split,
              let detail = container.branches.first(where: { $0.id == "detail" }),
              case .stack(let stack) = detail.node else {
            Issue.record("Expected a split root with an independent detail stack")
            return
        }
        #expect(stack.path == [.detail(id: "visible")])
        #expect(stack.presentation?.route == .modal)
        #expect(recorder.events.contains { event in
            guard case .rejected(_, _, _, let reason, _) = event,
                  case .mutation(.blockedByPresentation(["detail"])) = reason else {
                return false
            }
            return true
        })
    }

    @Test("Three-column split host constructs independent column scopes")
    func threeColumnConstruction() {
        let host = RouterThreeColumnSplitHost(
            RouterSplitHostRoute.self,
            initialSidebarPath: [.detail(id: "sidebar")],
            initialContentPath: [.detail(id: "content")],
            initialDetailPath: [.detail(id: "detail")]
        ) {
            Text("Sidebar")
        } content: {
            Text("Content")
        } detail: {
            Text("Detail")
        }

        _ = host.body
    }

    // Exact restoration may replace the root with any valid shape. SwiftUI
    // re-runs these initializers on every parent body pass, so a root that is
    // not the host's split shape must render rather than trap.
    @Test("Split hosts render over a store whose root is not a split container")
    func nonSplitRootDoesNotAbort() throws {
        let restored = RouterState<RouterSplitHostRoute>.rootStack(path: [.detail(id: "restored")])
        let store = RouterStore(initialState: restored)

        _ = try renderRouterSplitHost(RouterSplitHost(
            store: store,
            sidebar: { Text("Sidebar") },
            root: { Text("Detail") }
        ))
        _ = try renderRouterSplitHost(RouterThreeColumnSplitHost(
            store: store,
            sidebar: { Text("Sidebar") },
            content: { Text("Content") },
            detail: { Text("Detail") }
        ))

        #expect(store.state == restored)
    }

    // A root of another shape can carry branches named like the split
    // columns. The host renders over it without owning its topology, so its
    // default link must not push into the same-named branch.
    @Test("Split host links never write into a root of another shape")
    func mismatchedRootRejectsSplitLinks() throws {
        let tabs = try RouterState<RouterSplitHostRoute>(root: .container(.init(
            style: .tabs,
            selection: "detail",
            branches: [RouterBranch(id: "sidebar"), RouterBranch(id: "detail")]
        )))
        #expect(throws: RouterMutationError.incompatibleNavigationTopology(.root)) {
            try splitHostLinkPlan(.detail(id: "link"), tabs, detailScopeID: "detail")
        }

        let split = try makeSplitStore(threeColumn: false).state
        let plan = try splitHostLinkPlan(.detail(id: "link"), split, detailScopeID: "detail")
        #expect(plan.state.node(at: ["detail"]) == .stack(path: [.detail(id: "link")]))
    }

    @Test("Split hosts render over the other column count's split state")
    func mismatchedColumnCountDoesNotAbort() throws {
        let twoColumn = try makeSplitStore(threeColumn: false)
        let threeColumn = try makeSplitStore(threeColumn: true)
        let twoColumnState = twoColumn.state
        let threeColumnState = threeColumn.state

        _ = try renderRouterSplitHost(RouterSplitHost(
            store: threeColumn,
            sidebar: { Text("Sidebar") },
            root: { Text("Detail") }
        ))
        _ = try renderRouterSplitHost(RouterThreeColumnSplitHost(
            store: twoColumn,
            sidebar: { Text("Sidebar") },
            content: { Text("Content") },
            detail: { Text("Detail") }
        ))

        #expect(twoColumn.state == twoColumnState)
        #expect(threeColumn.state == threeColumnState)
    }

    @Test("Two- and three-column hosts follow replacement application-owned stores")
    func externalStoreReplacement() async throws {
#if canImport(AppKit)
        let firstTwo = try makeSplitStore(threeColumn: false)
        let secondTwo = try makeSplitStore(threeColumn: false)
        let twoObservations = RouterSplitReplacementObservations()
        _ = await secondTwo.perform(
            .push(.detail(id: "second-two")).inScope("detail")
        )
        let twoView = RouterSplitHost(
            store: firstTwo,
            sidebar: { Text("Sidebar") },
            root: {
                RouterSplitReplacementProbe(
                    generation: 0,
                    observations: twoObservations
                )
            }
        )
        let twoHost = try renderRouterSplitHost(twoView)
        for _ in 0..<8 { await Task.yield() }

        twoHost.rootView = RouterSplitHost(
            store: secondTwo,
            sidebar: { Text("Sidebar") },
            root: {
                RouterSplitReplacementProbe(
                    generation: 1,
                    observations: twoObservations
                )
            }
        )
        await renderRouterSplitHostReplacement(twoHost)
        for _ in 0..<8 { await Task.yield() }
        #expect(firstTwo.state.node(at: ["detail"]) == .stack())
        #expect(twoObservations.paths[1] == [.detail(id: "second-two")])

        let firstThree = try makeSplitStore(threeColumn: true)
        let secondThree = try makeSplitStore(threeColumn: true)
        let threeObservations = RouterSplitReplacementObservations()
        _ = await secondThree.perform(
            .push(.detail(id: "second-three")).inScope("detail")
        )
        let threeView = RouterThreeColumnSplitHost(
            store: firstThree,
            sidebar: { Text("Sidebar") },
            content: { Text("Content") },
            detail: {
                RouterSplitReplacementProbe(
                    generation: 0,
                    observations: threeObservations
                )
            }
        )
        let threeHost = try renderRouterSplitHost(threeView)
        for _ in 0..<8 { await Task.yield() }

        threeHost.rootView = RouterThreeColumnSplitHost(
            store: secondThree,
            sidebar: { Text("Sidebar") },
            content: { Text("Content") },
            detail: {
                RouterSplitReplacementProbe(
                    generation: 1,
                    observations: threeObservations
                )
            }
        )
        await renderRouterSplitHostReplacement(threeHost)
        for _ in 0..<8 { await Task.yield() }
        #expect(firstThree.state.node(at: ["detail"]) == .stack())
        #expect(threeObservations.paths[1] == [.detail(id: "second-three")])
#else
        throw Skip("RouterSplitHost replacement rendering requires AppKit.")
#endif
    }
}

@MainActor
private func makeSplitStore(
    threeColumn: Bool
) throws -> RouterStore<RouterSplitHostRoute> {
    let split = try RouterSplitState(
        sidebar: "sidebar",
        content: threeColumn ? "content" : nil,
        detail: "detail"
    )
    var branches = [RouterBranch<RouterSplitHostRoute>(id: "sidebar")]
    if threeColumn { branches.append(.init(id: "content")) }
    branches.append(.init(id: "detail"))
    let container = try RouterContainerState(
        style: .split,
        selection: "detail",
        branches: branches,
        split: split
    )
    return RouterStore(initialState: try RouterState(root: .container(container)))
}

#if canImport(AppKit)
@MainActor
@discardableResult
private func renderRouterSplitHost<V: View>(_ view: V) throws -> NSHostingView<V> {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 96, height: 96)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    return hostingView
}

@MainActor
private func renderRouterSplitHostReplacement<V: View>(
    _ hostingView: NSHostingView<V>
) async {
    hostingView.layoutSubtreeIfNeeded()
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
    hostingView.layoutSubtreeIfNeeded()
}
#else
@MainActor
private func renderRouterSplitHost<V: View>(_ view: V) throws {
    throw Skip("RouterSplitHost authority rendering requires AppKit.")
}
#endif
#endif
