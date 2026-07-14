// MARK: - RouterBehaviorTests.swift
// InnoRouterMacrosBehaviorTests - @Router runtime composition

#if canImport(InnoRouterMacrosPlugin)

import SwiftUI
import Testing

import InnoRouterMacros

@Router
private enum BehaviorRouterRoute {
    case detail(id: String)
    case settings

    var destination: some View {
        switch self {
        case .detail(let id):
            Text("Detail \(id)")
        case .settings:
            Text("Settings")
        }
    }
}

@Router
public enum PublicBehaviorRouterRoute {
    case settings

    private var destination: some View {
        Text("Settings")
    }
}

@Router
private enum GenericBehaviorRouterRoute<Value: Hashable & Sendable> {
    case detail(Value)

    var destination: some View {
        Text("Detail")
    }
}

@Router
@Routable
private enum CasePathBehaviorRouterRoute {
    case detail(id: String)

    var destination: some View {
        Text("Detail")
    }
}

@Suite("@Router behavior")
struct RouterBehaviorTests {
    @Test("Generated destination witness composes with RouterHost")
    @MainActor
    func generatedDestinationAndHost() {
        _ = BehaviorRouterRoute.destination(for: .settings)

        let host = RouterHost(BehaviorRouterRoute.self) {
            Text("Root")
        }
        _ = host.body
    }

    @Test("Generated route conformance works with NavigationStore")
    @MainActor
    func generatedRouteConformance() {
        let store = NavigationStore<BehaviorRouterRoute>()

        store.send(.go(.detail(id: "42")))

        #expect(store.state.path == [.detail(id: "42")])
    }

    @Test("Public routes can keep their destination hook non-public")
    @MainActor
    func publicRouteDestinationWitness() {
        _ = PublicBehaviorRouterRoute.destination(for: .settings)
    }

    @Test("Constrained generic routes retain their payload type")
    @MainActor
    func constrainedGenericRoute() {
        let store = NavigationStore<GenericBehaviorRouterRoute<String>>()

        store.send(.go(.detail("42")))

        #expect(store.state.path == [.detail("42")])
    }

    @Test("Router composes with Routable when case paths are needed")
    func routableComposition() {
        let route = CasePathBehaviorRouterRoute.detail(id: "42")

        #expect(route[case: CasePathBehaviorRouterRoute.Cases.detail] == "42")
    }
}

#endif
