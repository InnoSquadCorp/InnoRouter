import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum MacroFirstRuntimeRoute: DestinationRoute {
    case detail(id: String)
    case settings

    static func destination(for route: Self) -> some View {
        switch route {
        case .detail(let id):
            Text("Detail \(id)")
        case .settings:
            Text("Settings")
        }
    }
}

@Suite("Macro-first runtime")
struct MacroFirstRuntimeTests {
    @MainActor
    private final class IntentRecorder {
        var intents: [NavigationIntent<MacroFirstRuntimeRoute>] = []
    }

    @Test("RouterActions maps convenience methods to navigation intents")
    @MainActor
    func routerActionsIntentMapping() {
        let recorder = IntentRecorder()
        let router = RouterActions<MacroFirstRuntimeRoute> { intent in
            recorder.intents.append(intent)
        }

        router(.detail(id: "call"))
        router.go(.detail(id: "go"))
        router.goMany([.settings, .detail(id: "many")])
        router.back()
        router.back(by: 2)
        router.back(to: .settings)
        router.backToRoot()
        router.replaceStack(with: [.settings])
        router.backOrGo(to: .detail(id: "fallback"))
        router.goIfNeeded(.settings)

        #expect(recorder.intents == [
            .go(.detail(id: "call")),
            .go(.detail(id: "go")),
            .goMany([.settings, .detail(id: "many")]),
            .back,
            .backBy(2),
            .backTo(.settings),
            .backToRoot,
            .replaceStack([.settings]),
            .backOrPush(.detail(id: "fallback")),
            .pushUniqueRoot(.settings),
        ])
    }

    @Test("Explicit send remains available as an escape hatch")
    @MainActor
    func routerActionsExplicitSend() {
        let recorder = IntentRecorder()
        let router = RouterActions<MacroFirstRuntimeRoute> { intent in
            recorder.intents.append(intent)
        }

        router.send(.backToRoot)

        #expect(recorder.intents == [.backToRoot])
    }

    @Test("DestinationRoute removes the destination closure from NavigationHost")
    @MainActor
    func destinationRouteNavigationHostConstruction() {
        let store = NavigationStore<MacroFirstRuntimeRoute>()
        let host = NavigationHost(store: store) {
            Text("Root")
        }

        _ = host.body
        store.send(.go(.settings))

        #expect(store.state.path == [.settings])
    }

    @Test("RouterHost constructs a locally owned simple router")
    @MainActor
    func routerHostConstruction() {
        let host = RouterHost(MacroFirstRuntimeRoute.self) {
            Text("Root")
        }

        _ = host.body
    }

    @Test("EnvironmentRouter can be declared without exposing a store")
    @MainActor
    func environmentRouterConstruction() {
        struct ChildView: View {
            @EnvironmentRouter(MacroFirstRuntimeRoute.self) private var router

            var body: some View {
                Button("Settings") {
                    router.go(.settings)
                }
            }
        }

        _ = ChildView().body
    }
}
