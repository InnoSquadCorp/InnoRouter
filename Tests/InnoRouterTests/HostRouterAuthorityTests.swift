#if canImport(AppKit)
import AppKit
#endif
import Observation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum HostAuthorityRoute: Route {
    case first
    case second
    case modal
}

@MainActor
private struct HostAuthorityProbe: View {
    @EnvironmentRouter(HostAuthorityRoute.self) private var router

    let action: @MainActor (RouterActions<HostAuthorityRoute>) -> Void

    var body: some View {
        Color.clear.onAppear {
            action(router)
        }
    }
}

@Observable
@MainActor
private final class HostAuthorityCoordinator: Coordinator {
    let store = NavigationStore<HostAuthorityRoute>()

    @ViewBuilder
    func destination(for route: HostAuthorityRoute) -> some View {
        EmptyView()
    }
}

@Suite("Host RouterAuthority publication", .tags(.unit))
@MainActor
struct HostRouterAuthorityTests {
    @Test("NavigationHost publishes navigation-only nearest authority")
    func navigationHostAuthority() throws {
        let store = NavigationStore<HostAuthorityRoute>()
        var outerModalDispatches = 0

        let host = NavigationHost(
            store: store,
            destination: { _ in EmptyView() },
            root: {
                HostAuthorityProbe { router in
                    router.go(.first)
                    router.sheet(.modal)
                }
            }
        )
        .routerAuthority(
            for: HostAuthorityRoute.self,
            modal: { _ in outerModalDispatches += 1 }
        )
        .innoRouterEnvironmentMissingPolicy(.logAndDegrade)

        _ = try renderHostAuthority(host)

        #expect(store.state.path == [.first])
        #expect(outerModalDispatches == 0)
    }

    @Test("ModalHost publishes modal-only nearest authority")
    func modalHostAuthority() throws {
        let store = ModalStore<HostAuthorityRoute>()
        var outerNavigationDispatches = 0

        let host = ModalHost(
            store: store,
            destination: { _ in EmptyView() },
            content: {
                HostAuthorityProbe { router in
                    router.sheet(.modal)
                    router.go(.first)
                }
            }
        )
        .routerAuthority(
            for: HostAuthorityRoute.self,
            navigation: { _ in outerNavigationDispatches += 1 }
        )
        .innoRouterEnvironmentMissingPolicy(.logAndDegrade)

        _ = try renderHostAuthority(host)

        #expect(store.currentPresentation?.route == .modal)
        #expect(outerNavigationDispatches == 0)
    }

    @Test("CoordinatorHost publishes navigation-only nearest authority")
    func coordinatorHostAuthority() throws {
        let coordinator = HostAuthorityCoordinator()
        var outerModalDispatches = 0

        let host = CoordinatorHost(coordinator: coordinator) {
            HostAuthorityProbe { router in
                router.go(.second)
                router.sheet(.modal)
            }
        }
        .routerAuthority(
            for: HostAuthorityRoute.self,
            modal: { _ in outerModalDispatches += 1 }
        )
        .innoRouterEnvironmentMissingPolicy(.logAndDegrade)

        _ = try renderHostAuthority(host)

        #expect(coordinator.store.state.path == [.second])
        #expect(outerModalDispatches == 0)
    }

#if !os(watchOS)
    @Test("NavigationSplitHost publishes navigation-only nearest authority")
    func navigationSplitHostAuthority() throws {
        let store = NavigationStore<HostAuthorityRoute>()
        var outerModalDispatches = 0

        let host = NavigationSplitHost(
            store: store,
            sidebar: { EmptyView() },
            destination: { _ in EmptyView() },
            root: {
                HostAuthorityProbe { router in
                    router.go(.first)
                    router.sheet(.modal)
                }
            }
        )
        .routerAuthority(
            for: HostAuthorityRoute.self,
            modal: { _ in outerModalDispatches += 1 }
        )
        .innoRouterEnvironmentMissingPolicy(.logAndDegrade)

        _ = try renderHostAuthority(host)

        // NavigationSplitView may realize the detail column more than once;
        // the last route proves its nearest authority handled the action.
        #expect(store.state.path.last == .first)
        #expect(outerModalDispatches == 0)
    }

    @Test("CoordinatorSplitHost publishes navigation-only nearest authority")
    func coordinatorSplitHostAuthority() throws {
        let coordinator = HostAuthorityCoordinator()
        var outerModalDispatches = 0

        let host = CoordinatorSplitHost(
            coordinator: coordinator,
            sidebar: { EmptyView() },
            root: {
                HostAuthorityProbe { router in
                    router.go(.second)
                    router.sheet(.modal)
                }
            }
        )
        .routerAuthority(
            for: HostAuthorityRoute.self,
            modal: { _ in outerModalDispatches += 1 }
        )
        .innoRouterEnvironmentMissingPolicy(.logAndDegrade)

        _ = try renderHostAuthority(host)

        // NavigationSplitView may realize the detail column more than once;
        // the last route proves its nearest authority handled the action.
        #expect(coordinator.store.state.path.last == .second)
        #expect(outerModalDispatches == 0)
    }
#endif
}

#if canImport(AppKit)
@MainActor
@discardableResult
private func renderHostAuthority<V: View>(_ view: V) throws -> NSHostingView<V> {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 96, height: 96)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    return hostingView
}
#else
@MainActor
private func renderHostAuthority<V: View>(_ view: V) throws {
    throw Skip("Host authority rendering tests require AppKit.")
}
#endif
