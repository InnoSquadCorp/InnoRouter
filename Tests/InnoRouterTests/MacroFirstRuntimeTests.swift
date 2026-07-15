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

    @MainActor
    private final class FlowEventRecorder {
        var events: [FlowEvent<MacroFirstRuntimeRoute>] = []
    }

    @Test("RouterActions maps convenience methods to navigation intents")
    @MainActor
    func routerActionsIntentMapping() {
        let recorder = IntentRecorder()
        let router = RouterActions<MacroFirstRuntimeRoute> { intent in
            recorder.intents.append(intent)
        }

        router.go(.detail(id: "go"))
        router.back()
        router.back(by: 2)
        router.back(to: .settings)
        router.backToRoot()

        #expect(recorder.intents == [
            .go(.detail(id: "go")),
            .back,
            .backBy(2),
            .backTo(.settings),
            .backToRoot,
        ])
    }

    @Test("Explicit send remains available as an escape hatch")
    @MainActor
    func routerActionsExplicitSend() {
        let recorder = IntentRecorder()
        let router = RouterActions<MacroFirstRuntimeRoute> { intent in
            recorder.intents.append(intent)
        }

        router.send(.goMany([.settings, .detail(id: "many")]))
        router.send(.replaceStack([.settings]))
        router.send(.backOrPush(.detail(id: "fallback")))
        router.send(.pushUniqueRoot(.settings))

        #expect(recorder.intents == [
            .goMany([.settings, .detail(id: "many")]),
            .replaceStack([.settings]),
            .backOrPush(.detail(id: "fallback")),
            .pushUniqueRoot(.settings),
        ])
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

    @Test("FlowHost removes the destination closure for a DestinationRoute")
    @MainActor
    func destinationRouteFlowHostConstruction() {
        let store = FlowStore<MacroFirstRuntimeRoute>()
        let host = FlowHost(store: store) {
            Text("Root")
        }

        _ = host.body
        store.send(.push(.settings))

        #expect(store.path == [.push(.settings)])
    }

    @Test("RouterHost constructs a locally owned push and modal router")
    @MainActor
    func routerHostConstruction() {
        let host = RouterHost(
            MacroFirstRuntimeRoute.self,
            initial: [.push(.settings)]
        ) {
            Text("Root")
        }

        _ = host.body
    }

    @Test("RouterModalHost constructs a locally owned modal router")
    @MainActor
    func routerModalHostConstruction() {
        let current = ModalPresentation(
            route: MacroFirstRuntimeRoute.settings,
            style: .sheet
        )
        let queued = ModalPresentation(
            route: MacroFirstRuntimeRoute.detail(id: "queued"),
            style: .fullScreenCover
        )
        let host = RouterModalHost(
            MacroFirstRuntimeRoute.self,
            initial: current,
            queued: [queued]
        ) {
            Text("Root")
        }

        _ = host.body
    }

    @Test("Macro-first diagnostics preserve the caller's flow event hook")
    @MainActor
    func macroFirstDiagnosticsChainUserOnEvent() {
        let recorder = FlowEventRecorder()
        let configuration = FlowStoreConfiguration<MacroFirstRuntimeRoute>(
            onEvent: { event in
                recorder.events.append(event)
            }
        ).withMacroFirstDiagnostics(hostName: "RouterHost")
        let store = FlowStore(
            initial: [.sheet(.settings)],
            configuration: configuration
        )

        store.send(.push(.detail(id: "blocked")))

        #expect(
            recorder.events.contains(
                .intentRejected(.push(.detail(id: "blocked")), .pushBlockedByModalTail)
            )
        )
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
