#if canImport(AppKit)
import AppKit
#endif
import Observation
import SwiftUI
import Testing

import InnoRouter

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
#else
@MainActor
private func renderRouterSplitHost<V: View>(_ view: V) throws {
    throw Skip("RouterSplitHost authority rendering requires AppKit.")
}
#endif
#endif
