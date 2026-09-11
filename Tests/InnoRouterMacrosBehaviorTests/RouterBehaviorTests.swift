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

    @TabItem(
        "Settings",
        systemImage: "gear",
        selectedSystemImage: "gearshape.fill",
        role: .search
    )
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

@Router
private enum MixedBehaviorRouter {
    @TabItem("Home", systemImage: "house")
    case home

    @TabItem("Settings", systemImage: "gear")
    case settings

    case detail(id: String)

    var destination: some View {
        Text("Destination")
    }
}

@Router
private enum SceneBehaviorRouter {
    @Scene(.window, id: "editor")
    case editor

    @Scene(.immersiveSpace, id: "studio")
    case studio

    case detail(id: String)

    var destination: some View {
        Text("Destination")
    }
}

private struct EditorResult: Hashable, Sendable {
    let saved: Bool
}

@Router
private enum PresentationBehaviorRouter {
    @PresentationResult(Bool.self)
    case login

    @PresentationResult(EditorResult.self)
    case editor(id: String)

    var destination: some View {
        Text("Destination")
    }
}

@Router
private enum AvailablePresentationBehaviorRouter {
    @available(macOS 26, *)
    @PresentationResult(Bool.self)
    case future

    var destination: some View { Text("Destination") }
}

@Router
private enum FeatureBehaviorRoute {
    case home
    case detail(id: String)

    var destination: some View { Text("Feature") }
}

@Router
private enum FeatureParentRoute {
    @FeatureRoute("account.primary")
    case account(FeatureBehaviorRoute)

    @FeatureRoute("account.secondary")
    case secondary(FeatureBehaviorRoute)

    case settings

    var destination: some View { Text("Parent") }
}

@Suite("@Router behavior")
struct RouterBehaviorTests {
    @Test("Presentation factories retain their route availability")
    func presentationAvailability() {
        if #available(macOS 26, *) {
            #expect(AvailablePresentationBehaviorRouter.Presentation.future.route == .future)
        }
    }

    @Test("Feature mappings preserve one parent store and sibling state")
    @MainActor
    func featureRouteComposition() async throws {
        let featureBranch: RouterScopeID = "feature"
        let siblingBranch: RouterScopeID = "sibling"
        let root = try RouterContainerState<FeatureParentRoute>(
            style: .custom("features"),
            selection: featureBranch,
            branches: [
                .init(id: featureBranch, node: .stack(path: [.account(.home)])),
                .init(id: siblingBranch, node: .stack(path: [.settings])),
            ]
        )
        var observedActions: [RouterAction<FeatureParentRoute>] = []
        let store = RouterStore(
            initialState: try RouterState(root: .container(root)),
            configuration: .init(
                policies: [
                    RouterPolicy(name: "observe") { transition in
                        observedActions.append(transition.action)
                        return .allow
                    }
                ]
            )
        )
        let parentScope = store.scope(at: [featureBranch])
        let feature = RouterFeatureScope(
            parent: parentScope,
            mapping: FeatureParentRoute.Feature.account
        )

        let outcome = await feature.perform(.push(.detail(id: "42")))

        guard case .applied(let id, _, let after, let revision) = outcome else {
            Issue.record("Expected the feature action to use the parent pipeline")
            return
        }
        #expect(revision == store.revision)
        #expect(id == outcome.id)
        #expect(after.root == .stack(path: [.home, .detail(id: "42")]))
        #expect(observedActions == [.push(.account(.detail(id: "42"))).inScope(featureBranch)])
        #expect(store.state.node(at: [siblingBranch]) == .stack(path: [.settings]))

        let replacement = try RouterPlan<FeatureBehaviorRoute> {
            .stack([.detail(id: "replacement")])
        }
        _ = await feature.perform(.apply(replacement))
        #expect(feature.node == .stack(path: [.detail(id: "replacement")]))
        #expect(store.state.node(at: [siblingBranch]) == .stack(path: [.settings]))
        #expect(FeatureParentRoute.Feature.account.id == "account.primary")
        #expect(FeatureParentRoute.Feature.secondary.id == "account.secondary")
        #expect(FeatureParentRoute.Feature.catalog == [
            .init(
                id: "account.primary",
                namespace: "FeatureParentRoute.account.primary",
                childRouteTypeName: "FeatureBehaviorRoute"
            ),
            .init(
                id: "account.secondary",
                namespace: "FeatureParentRoute.account.secondary",
                childRouteTypeName: "FeatureBehaviorRoute"
            ),
        ])
    }

    @Test("Feature presentation results reuse the parent store waiter exactly once")
    @MainActor
    func featurePresentationResult() async throws {
        let store = RouterStore<FeatureParentRoute>(
            initialState: .rootStack(path: [.account(.home)])
        )
        let feature = RouterFeatureScope(
            parent: store.scope(),
            mapping: FeatureParentRoute.Feature.account
        )
        var events = store.events.makeAsyncIterator()
        let request = RouterPresentationRequest<FeatureBehaviorRoute, Bool>(
            route: .detail(id: "approval"),
            style: .sheet
        )
        let result = Task { @MainActor in
            await feature.present(request)
        }

        while let event = await events.next() {
            guard case .committed(_, _, let state, _, _) = event,
                  case .stack(let stack) = state.root,
                  stack.presentation != nil else { continue }
            break
        }
        try await feature.finishPresentation(request, returning: true)

        #expect(await result.value == .value(true))
        #expect(store.state.root == .stack(path: [.account(.home)]))
    }

    @Test("Generated destination witness composes with RouterHost")
    @MainActor
    func generatedDestinationAndHost() {
        _ = BehaviorRouterRoute.destination(for: .settings)

        let host = RouterHost(BehaviorRouterRoute.self) {
            Text("Root")
        }
        _ = host.body
    }

    @Test("Generated route conformance unlocks the canonical store factory")
    @MainActor
    func generatedStoreFactory() async {
        let store = BehaviorRouterRoute.makeRouterStore()

        let outcome = await store.perform(.push(.detail(id: "42")))

        #expect(store.state.root == .stack(path: [.detail(id: "42")]))
        guard case .applied = outcome else {
            Issue.record("Expected generated router store to apply the action")
            return
        }
    }

    @Test("Generated route conformance works with RouterStore")
    @MainActor
    func generatedRouteConformance() async {
        let store = RouterStore<BehaviorRouterRoute>()

        _ = await store.perform(.push(.detail(id: "42")))

        #expect(store.state.root == .stack(path: [.detail(id: "42")]))
    }

    @Test("Public routes can keep their destination hook non-public")
    @MainActor
    func publicRouteDestinationWitness() {
        _ = PublicBehaviorRouterRoute.destination(for: .settings)
    }

    @Test("Constrained generic routes retain their payload type")
    @MainActor
    func constrainedGenericRoute() async {
        let store = RouterStore<GenericBehaviorRouterRoute<String>>()

        _ = await store.perform(.push(.detail("42")))

        #expect(store.state.root == .stack(path: [.detail("42")]))
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
        #expect(BehaviorRouterTab.Tab.allCases == [.home, .settings])
        #expect(BehaviorRouterTab.Tab.home.title.key == "Home")
        #expect(BehaviorRouterTab.Tab.settings.systemImage == "gear")
        #expect(BehaviorRouterTab.Tab.settings.selectedSystemImage == "gearshape.fill")
        #expect(BehaviorRouterTab.Tab.settings.role == .search)
        #expect(BehaviorRouterTab.Tab.home.selectedSystemImage == nil)
        #expect(BehaviorRouterTab.Tab.home.role == .standard)
        #expect(BehaviorRouterTab.Tab.home.routerScopeID == "home")
        #expect(BehaviorRouterTab.Tab.settings.routerScopeID == "settings")
        #expect(BehaviorRouterTab.routerTabs.map(\.root) == [.home, .settings])

        let host = RouterTabHost(BehaviorRouterTab.self, initial: .home)
        _ = host.body
    }

    @Test("One router can declare tab roots and pushed destinations")
    @MainActor
    func mixedTabAndDestinationRouter() {
        #expect(MixedBehaviorRouter.Tab.allCases == [.home, .settings])
        #expect(MixedBehaviorRouter.routerTabs.map(\.root) == [.home, .settings])
        let host = RouterTabHost(MixedBehaviorRouter.self, initial: .home)

        _ = host.body
    }

    @Test("Scene metadata forms a partial macro-first route catalog")
    func generatedSceneCatalog() {
        #expect(
            SceneBehaviorRouter.routerScenes == [
                .init(route: .editor, id: "editor", style: .window),
                .init(route: .studio, id: "studio", style: .immersiveSpace),
            ]
        )
        #expect(SceneBehaviorRouter.routerScene(for: .detail(id: "42")) == nil)
    }

    @Test("Presentation result metadata generates compile-time typed requests")
    func generatedPresentationRequests() {
        let login: RouterPresentationRequest<PresentationBehaviorRouter, Bool> =
            PresentationBehaviorRouter.Presentation.login
        let editor: RouterPresentationRequest<PresentationBehaviorRouter, EditorResult> =
            PresentationBehaviorRouter.Presentation.editor(id: "42")

        #expect(login.route == .login)
        #expect(editor.route == .editor(id: "42"))
    }
}

#endif
