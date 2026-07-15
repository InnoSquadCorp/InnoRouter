// MARK: - NavigationEffectGuardedRaceTests.swift
// InnoRouterTests - executeGuarded / resumePendingDeepLinkIfAllowed stale-command coverage
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterDeepLink
import InnoRouterEffects

private enum RaceRoute: Route {
    case home
    case settings
    case detail(id: String)
}

@Suite("executeGuarded stale-command race regression")
struct NavigationEffectGuardedRaceTests {
    @Test("executeGuarded rejects a command whose preconditions were invalidated during prepare")
    @MainActor
    func testExecuteGuarded_staleCommandAfterConcurrentPop() async {
        let store = NavigationStore<RaceRoute>()
        let handler = NavigationEffectHandler(navigator: store)
        var iterator = handler.events.makeAsyncIterator()

        store.execute(.push(.home))
        store.execute(.push(.settings))
        #expect(store.state.path == [.home, .settings])

        // prepare suspends then concurrently pops the stack to empty, invalidating `.pop`.
        let result = await handler.executeGuarded(.pop) { command in
            await Task.yield()
            store.execute(.popToRoot)
            return .proceed(command)
        }

        guard case .cancelled(.staleAfterPrepare(let staleCommand)) = result else {
            Issue.record("expected .staleAfterPrepare, got \(result)")
            return
        }
        #expect(staleCommand == .pop)
        #expect(store.state.path.isEmpty)
        guard case .command(let command, let eventResult) = await iterator.next() else {
            Issue.record("expected .command event")
            return
        }
        #expect(command == .pop)
        #expect(eventResult == result)
    }

    @Test("executeGuarded still proceeds when prepare returns a command that remains valid")
    @MainActor
    func testExecuteGuarded_proceedsWhenCommandRemainsValid() async {
        let store = NavigationStore<RaceRoute>()
        let handler = NavigationEffectHandler(navigator: store)

        let result = await handler.executeGuarded(.push(.home)) { command in
            .proceed(command)
        }

        #expect(result == .success)
        #expect(store.state.path == [.home])
    }

    @Test("executeGuarded forwards explicit cancellations unchanged")
    @MainActor
    func testExecuteGuarded_explicitCancelUnchanged() async {
        let store = NavigationStore<RaceRoute>()
        let handler = NavigationEffectHandler(navigator: store)

        let result = await handler.executeGuarded(.push(.home)) { _ in
            .cancel(.custom("denied"))
        }

        #expect(result == .cancelled(.custom("denied")))
        #expect(store.state.path.isEmpty)
    }

    @Test("resumePendingDeepLinkIfAllowed defers when the pending plan no longer applies")
    @MainActor
    func testResumePendingDeepLink_commandInvalidatedBeforeExecute() async throws {
        let store = NavigationStore<RaceRoute>()
        store.execute(.push(.home))
        store.execute(.push(.detail(id: "42")))
        let isAuthenticated = Mutex<Bool>(false)
        let matcher = DeepLinkMatcher<RaceRoute> {
            DeepLinkMapping("/detail/:id") { params in
                guard let id = params.firstValue(forName: "id") else { return nil }
                return .detail(id: id)
            }
        }
        let handler = DeepLinkEffectHandler<RaceRoute>(
            navigator: store,
            matcher: matcher,
            authenticationPolicy: .required(
                shouldRequireAuthentication: { _ in true },
                isAuthenticated: { isAuthenticated.withLock { $0 } }
            ),
            plan: { route in
                // Depend on a popTo that presumes .home is already on the stack;
                // if the stack is cleared during authorize, this plan is stale.
                NavigationPlan(commands: [.popTo(.home), .push(route)])
            }
        )

        let firstOutcome = handler.handle(URL(string: "scheme://app/detail/7")!)
        guard case .pending(let pending) = firstOutcome else {
            Issue.record("expected initial .pending, got \(firstOutcome)")
            return
        }
        #expect(pending.route == .home)

        isAuthenticated.withLock { $0 = true }

        let result = await handler.resumePendingDeepLinkIfAllowed { _ in
            await Task.yield()
            store.execute(.popToRoot) // invalidates the .popTo(.home) step in the plan
            return true
        }

        guard case .applicationRejected(let plan, let failure) = result else {
            Issue.record("expected .applicationRejected after stale re-validation, got \(result)")
            return
        }
        #expect(plan == pending.plan)
        #expect(failure.command == .popTo(.home))
        #expect(failure.result == .routeNotFound(.home))
        #expect(handler.pendingDeepLink == nil)
        #expect(store.state.path.isEmpty)
    }
}
