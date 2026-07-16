// MARK: - RouterBehaviorTests.swift
// InnoRouterMacrosBehaviorTests - @Router runtime composition

#if canImport(InnoRouterMacrosPlugin)

import Foundation
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

@Router
private enum OverloadedBehaviorRouterRoute {
    case settings

    var destination: some View {
        Text("Settings")
    }

    static func destination(for style: Int) -> String {
        "Style \(style)"
    }
}

@Router
private enum GenericOverloadedBehaviorRouterRoute<Value: Hashable & Sendable> {
    case detail(Value)

    var destination: some View {
        Text("Detail")
    }

    static func destination(for route: GenericOverloadedBehaviorRouterRoute<Int>) -> String {
        switch route {
        case .detail(let value):
            "Specialized \(value)"
        }
    }
}

@Router
private enum BehaviorRouterTab {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
    case settings

    var destination: some View {
        switch self {
        case .home:
            Text("Home")
        case .settings:
            Text("Settings")
        }
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

    @Test("Non-conflicting destination overload remains callable")
    @MainActor
    func destinationOverload() {
        #expect(OverloadedBehaviorRouterRoute.destination(for: 7) == "Style 7")
        _ = OverloadedBehaviorRouterRoute.destination(for: .settings)
    }

    @Test("Generic specializations remain valid destination overloads")
    @MainActor
    func genericDestinationOverload() {
        let route = GenericOverloadedBehaviorRouterRoute<Int>.detail(7)
        let output = GenericOverloadedBehaviorRouterRoute<String>.destination(for: route)

        #expect(output == "Specialized 7")
        _ = GenericOverloadedBehaviorRouterRoute<String>.destination(for: .detail("42"))
    }

    @Test("Tab metadata expands and composes with RouterTabHost")
    @MainActor
    func generatedRouterTabAndHost() {
        #expect(BehaviorRouterTab.allCases == [.home, .settings])
        #expect(BehaviorRouterTab.home.title.key == "Home")
        #expect(BehaviorRouterTab.settings.systemImage == "gear")

        let host = RouterTabHost(BehaviorRouterTab.self, initial: .home)
        _ = host.body
    }
}

#endif
