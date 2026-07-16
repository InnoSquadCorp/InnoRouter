#if canImport(AppKit)
import AppKit
#endif
import Foundation
import Observation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum RouterTabHostRoute: String, DestinationRoute, RouterTab {
    case home
    case inbox
    case settings

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .inbox: "Inbox"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .inbox: "tray"
        case .settings: "gearshape"
        }
    }

    static func destination(for route: Self) -> some View {
        RouterTabDestination(route: route)
    }
}

@MainActor
@Observable
private final class RouterTabHostRecorder {
    var appearances: [RouterTabHostRoute] = []
    var didDispatch = false
}

@MainActor
private struct RouterTabDestination: View {
    @EnvironmentRouter(RouterTabHostRoute.self) private var router
    @Environment(RouterTabHostRecorder.self) private var recorder

    let route: RouterTabHostRoute

    var body: some View {
        Text(route.title)
            .onAppear {
                recorder.appearances.append(route)
                guard route == .home, !recorder.didDispatch else { return }
                recorder.didDispatch = true
                router.select(.inbox)
                router.setBadge(4, for: .settings)
            }
    }
}

@Suite("RouterTabHost", .tags(.unit))
@MainActor
struct RouterTabHostTests {
    @Test("RouterTabState owns selection and normalized badge state")
    func stateOwnership() {
        let state = RouterTabState(
            initial: RouterTabHostRoute.home,
            badges: [.inbox: 2, .settings: 0]
        )

        #expect(state.selection == .home)
        #expect(state.badges == [.inbox: 2])

        state.send(.select(.settings))
        state.send(.setBadge(5, for: .home))
        state.send(.setBadge(0, for: .inbox))

        #expect(state.selection == .settings)
        #expect(state.badges == [.home: 5])

        state.send(.clearAllBadges)
        #expect(state.badges.isEmpty)
    }

    @Test("RouterActions maps tab methods to the internal host state")
    func routerActionMapping() {
        let state = RouterTabState(initial: RouterTabHostRoute.home)
        let router = RouterActions(
            authority: RouterAuthority(tab: state.actionHandler)
        )

        router.select(.inbox)
        router.setBadge(3, for: .inbox)
        router.setBadge(-1, for: .settings)

        #expect(state.selection == .inbox)
        #expect(state.badges == [.inbox: 3])

        router.clearBadge(for: .inbox)
        #expect(state.badges.isEmpty)

        router.setBadge(1, for: .home)
        router.setBadge(2, for: .settings)
        router.clearAllBadges()
        #expect(state.badges.isEmpty)
    }

    @Test("Nearest same-route authority does not inherit an outer tab capability")
    func nearestAuthorityReplacement() {
        var outerSelections: [RouterTabHostRoute] = []
        var environment = RouterEnvironment()
        environment.register(
            RouterAuthority(
                tab: { action in
                    guard case .select(let tab) = action else { return }
                    outerSelections.append(tab)
                }
            ),
            for: RouterTabHostRoute.self
        )
        environment.register(
            RouterAuthority(
                navigation: { _ in }
            ),
            for: RouterTabHostRoute.self
        )
        let snapshot = environment
        let router = RouterActions(
            routeType: RouterTabHostRoute.self,
            environmentMissingPolicy: .logAndDegrade,
            resolveEnvironment: { snapshot }
        )

        router.select(.settings)

        #expect(outerSelections.isEmpty)
    }

    @Test("Missing tab capability degrades without dispatching another capability")
    func missingTabCapability() {
        var navigationIntents: [NavigationIntent<RouterTabHostRoute>] = []
        let router = RouterActions(
            authority: RouterAuthority(
                navigation: { navigationIntents.append($0) }
            ),
            environmentMissingPolicy: .logAndDegrade
        )

        router.select(.settings)

        #expect(navigationIntents.isEmpty)
    }

    @Test("RouterTabHost constructs local state and publishes tab actions")
    func hostConstructionAndAuthority() throws {
        let state = RouterTabState(initial: RouterTabHostRoute.home)
        let recorder = RouterTabHostRecorder()
        let host = RouterTabHost(state: state)
            .environment(recorder)

        _ = try renderRouterTabHost(host)

        #expect(recorder.didDispatch)
        #expect(recorder.appearances.contains(.home))
        #expect(state.selection == .inbox)
        #expect(state.badges == [.settings: 4])
    }

    @Test("Tab action handlers are Sendable and main-actor isolated")
    func actionHandlerIsolation() {
        let state = RouterTabState(initial: RouterTabHostRoute.home)

        requireSendable(state.actionHandler)
        state.actionHandler(.select(.settings))

        #expect(state.selection == .settings)
    }

    private func requireSendable<T: Sendable>(_: T) {}
}

#if canImport(AppKit)
@MainActor
@discardableResult
private func renderRouterTabHost<V: View>(_ view: V) throws -> NSHostingView<V> {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return hostingView
}
#else
@MainActor
private func renderRouterTabHost<V: View>(_ view: V) throws {
    throw Skip("RouterTabHost rendering tests require AppKit.")
}
#endif
