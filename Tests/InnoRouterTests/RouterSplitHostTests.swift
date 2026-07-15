#if canImport(AppKit)
import AppKit
#endif
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
        case .detail(let id):
            Text("Detail \(id)")
        case .modal:
            Text("Modal")
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
private struct RawRouterSplitHostProbe: View {
    @EnvironmentNavigationIntent(RouterSplitHostRoute.self) private var navigation
    @EnvironmentModalIntent(RouterSplitHostRoute.self) private var modal

    let gate: RouterSplitHostInvocationGate

    var body: some View {
        Color.clear.onAppear {
            gate.run {
                modal(.present(.modal, style: .sheet))
                navigation(.go(.detail(id: "blocked")))
            }
        }
    }
}

@Suite("RouterSplitHost", .tags(.unit))
@MainActor
struct RouterSplitHostTests {
    @Test("macro-first split host can be constructed with generated destinations")
    func construction() {
        let host = RouterSplitHost(
            RouterSplitHostRoute.self,
            initial: [.push(.detail(id: "initial"))]
        ) {
            Text("Sidebar")
        } root: {
            Text("Select a route")
        }

        _ = host.body
    }

    @Test("split router authority preserves the FlowStore modal-tail invariant")
    func unifiedAuthority() throws {
        var events: [FlowEvent<RouterSplitHostRoute>] = []
        let store = FlowStore<RouterSplitHostRoute>(
            configuration: FlowStoreConfiguration { events.append($0) }
        )
        let gate = RouterSplitHostInvocationGate()
        let surface = RouterSplitFlowSurface(
            store: store,
            sidebar: { Text("Sidebar") },
            destination: RouterSplitHostRoute.destination(for:),
            root: { RouterSplitHostProbe(gate: gate) }
        )

        _ = try renderRouterSplitHost(surface)

        #expect(store.path == [
            .push(.detail(id: "visible")),
            .sheet(.modal),
        ])
        #expect(
            events.contains(
                .intentRejected(
                    .push(.detail(id: "blocked")),
                    .pushBlockedByModalTail
                )
            )
        )
    }

    @Test("raw split intent wrappers cannot bypass the FlowStore modal-tail invariant")
    func rawIntentAuthority() throws {
        var events: [FlowEvent<RouterSplitHostRoute>] = []
        let store = FlowStore<RouterSplitHostRoute>(
            configuration: FlowStoreConfiguration { events.append($0) }
        )
        let gate = RouterSplitHostInvocationGate()
        let surface = RouterSplitFlowSurface(
            store: store,
            sidebar: { Text("Sidebar") },
            destination: RouterSplitHostRoute.destination(for:),
            root: { RawRouterSplitHostProbe(gate: gate) }
        )

        _ = try renderRouterSplitHost(surface)

        #expect(store.path == [.sheet(.modal)])
        #expect(
            events.contains(
                .intentRejected(
                    .push(.detail(id: "blocked")),
                    .pushBlockedByModalTail
                )
            )
        )
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
