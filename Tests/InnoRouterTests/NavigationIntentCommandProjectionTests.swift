// MARK: - NavigationIntentCommandProjectionTests.swift
// InnoRouterTests - NavigationStore.commands(for:) projection from
// NavigationIntent to NavigationCommand plan.
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum ProjectionRoute: Route {
    case home
    case detail(Int)
    case settings
}

@Suite("NavigationStore.commands(for:) projection")
@MainActor
struct NavigationIntentCommandProjectionTests {

    // MARK: - State-independent intents

    @Test(".go(route) projects to [.push(route)]")
    func go_projectsToPush() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .go(.home))
        #expect(plan == [.push(.home)])
    }

    @Test(".back projects to [.pop]")
    func back_projectsToPop() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .back)
        #expect(plan == [.pop])
    }

    @Test(".backToRoot projects to [.popToRoot]")
    func backToRoot_projectsToPopToRoot() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .backToRoot)
        #expect(plan == [.popToRoot])
    }

    @Test(".replaceStack projects to [.replace(routes)]")
    func replaceStack_projectsToReplace() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .replaceStack([.home, .settings]))
        #expect(plan == [.replace([.home, .settings])])
    }

    @Test(".goMany([]) projects to an empty plan")
    func goMany_emptyProjectsToNoop() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .goMany([]))
        #expect(plan.isEmpty)
    }

    @Test(".goMany([single]) projects to a single push")
    func goMany_singleProjectsToPush() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .goMany([.home]))
        #expect(plan == [.push(.home)])
    }

    @Test(".goMany([multi]) projects to one atomic pushAll command")
    func goMany_multipleProjectsToPushAll() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .goMany([.home, .settings]))
        #expect(plan == [.pushAll([.home, .settings])])
    }

    // MARK: - State-dependent intents

    @Test(".backBy(N) where N == path.count projects to .popToRoot")
    func backBy_equalPathCount_projectsToPopToRoot() {
        let store = try! NavigationStore<ProjectionRoute>(
            initialPath: [.home, .detail(1), .settings]
        )
        let plan = store.commands(for: .backBy(3))
        #expect(plan == [.popToRoot])
    }

    @Test(".backBy(N) where N < path.count projects to .popCount(N)")
    func backBy_smallerThanPathCount_projectsToPopCount() {
        let store = try! NavigationStore<ProjectionRoute>(
            initialPath: [.home, .detail(1), .settings]
        )
        let plan = store.commands(for: .backBy(1))
        #expect(plan == [.popCount(1)])
    }

    @Test(".backOrPush(route) when route is on the stack projects to .popTo(route)")
    func backOrPush_routeOnStack_projectsToPopTo() {
        let store = try! NavigationStore<ProjectionRoute>(
            initialPath: [.home, .detail(1)]
        )
        let plan = store.commands(for: .backOrPush(.home))
        #expect(plan == [.popTo(.home)])
    }

    @Test(".backOrPush(route) when route is NOT on the stack projects to .push(route)")
    func backOrPush_routeNotOnStack_projectsToPush() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .backOrPush(.home))
        #expect(plan == [.push(.home)])
    }

    @Test(".pushUniqueRoot(route) when route is on the stack projects to []")
    func pushUniqueRoot_routeOnStack_projectsToEmpty() {
        let store = try! NavigationStore<ProjectionRoute>(
            initialPath: [.home]
        )
        let plan = store.commands(for: .pushUniqueRoot(.home))
        #expect(plan.isEmpty)
    }

    @Test(".pushUniqueRoot(route) when route is NOT on the stack projects to .push(route)")
    func pushUniqueRoot_routeNotOnStack_projectsToPush() {
        let store = NavigationStore<ProjectionRoute>()
        let plan = store.commands(for: .pushUniqueRoot(.home))
        #expect(plan == [.push(.home)])
    }

    // MARK: - send(_:) parity with the projection

    @Test("send(intent) executes exactly the projection of that intent")
    func send_executesProjection() {
        let store = NavigationStore<ProjectionRoute>()
        let intent: NavigationIntent<ProjectionRoute> =
            .goMany([.home, .detail(1), .settings])

        store.send(intent)

        // The projection said: one atomic pushAll command. Path ends at
        // exactly those routes.
        #expect(store.state.path == [.home, .detail(1), .settings])
    }
}
