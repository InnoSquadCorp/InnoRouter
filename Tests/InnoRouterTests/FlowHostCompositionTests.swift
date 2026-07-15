// MARK: - FlowHostCompositionTests.swift
// InnoRouterTests - FlowHost composition and environment dispatcher injection
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import SwiftUI
import InnoRouter
@testable import InnoRouterSwiftUI
#if canImport(AppKit)
import AppKit
#endif

private enum FlowHostRoute: Route {
    case landing
    case child
    case sheetChild
}

@Suite("FlowHost Composition Tests")
struct FlowHostCompositionTests {

    @Test("FlowHost body can be constructed over NavigationHost + ModalHost")
    @MainActor
    func flowHostConstructs() {
        let store = FlowStore<FlowHostRoute>()
        let host = FlowHost(
            store: store,
            destination: { _ in EmptyView() },
            root: { EmptyView() }
        )
        _ = host.body
    }

    @Test("FlowStore intentDispatcher forwards flow intents")
    @MainActor
    func flowStoreIntentDispatcherIsCachedAndForwardsIntents() {
        let store = FlowStore<FlowHostRoute>()
        let dispatcher = store.intentDispatcher

        dispatcher(.push(.landing))
        dispatcher(.push(.child))
        dispatcher(.presentSheet(.sheetChild))

        #expect(store.path == [.push(.landing), .push(.child), .sheet(.sheetChild)])
        #expect(store.modalStore.currentPresentation?.route == .sheetChild)
    }

    @Test("FlowStore navigation adapter maps the complete intent surface")
    @MainActor
    func flowStoreNavigationAdapterMapping() {
        #expect(FlowStore<FlowHostRoute>.flowIntent(for: .go(.landing)) == .push(.landing))
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(for: .goMany([.landing, .child]))
                == .pushMany([.landing, .child])
        )
        #expect(FlowStore<FlowHostRoute>.flowIntent(for: .back) == .pop)
        #expect(FlowStore<FlowHostRoute>.flowIntent(for: .backBy(2)) == .popCount(2))
        #expect(FlowStore<FlowHostRoute>.flowIntent(for: .backTo(.landing)) == .popTo(.landing))
        #expect(FlowStore<FlowHostRoute>.flowIntent(for: .backToRoot) == .popToRoot)
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(for: .replaceStack([.child]))
                == .replaceStack([.child])
        )
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(for: .backOrPush(.child))
                == .backOrPush(.child)
        )
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(for: .pushUniqueRoot(.landing))
                == .pushUniqueRoot(.landing)
        )
    }

    @Test("FlowStore modal adapter maps the complete intent surface")
    @MainActor
    func flowStoreModalAdapterMapping() {
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(
                for: ModalIntent.present(.landing, style: .sheet)
            ) == .presentSheet(.landing)
        )
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(
                for: ModalIntent.present(.child, style: .fullScreenCover)
            ) == .presentCover(.child)
        )
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(for: ModalIntent.dismiss)
                == .dismiss
        )
        #expect(
            FlowStore<FlowHostRoute>.flowIntent(for: ModalIntent.dismissAll)
                == .dismissAll
        )
    }

    @Test("EnvironmentRouter cannot push past a FlowHost modal tail")
    @MainActor
    func unifiedRouterCannotBypassFlowModalTail() throws {
        var events: [FlowEvent<FlowHostRoute>] = []
        let store = FlowStore<FlowHostRoute>(
            configuration: FlowStoreConfiguration { events.append($0) }
        )
        let host = FlowHost(
            store: store,
            destination: { _ in EmptyView() },
            root: {
                UnifiedFlowRouterProbe {
                    $0.sheet(.sheetChild)
                    $0.go(.child)
                }
            }
        )

        _ = try renderFlowHost(host)

        #expect(store.path == [.sheet(.sheetChild)])
        #expect(
            events.contains(
                .intentRejected(.push(.child), .pushBlockedByModalTail)
            )
        )
    }

    @Test("Raw environment intents cannot push past a FlowHost modal tail")
    @MainActor
    func rawIntentsCannotBypassFlowModalTail() throws {
        var events: [FlowEvent<FlowHostRoute>] = []
        let store = FlowStore<FlowHostRoute>(
            configuration: FlowStoreConfiguration { events.append($0) }
        )
        let host = FlowHost(
            store: store,
            destination: { _ in EmptyView() },
            root: { RawFlowIntentProbe() }
        )

        _ = try renderFlowHost(host)

        #expect(store.path == [.sheet(.sheetChild)])
        #expect(
            events.contains(
                .intentRejected(.push(.child), .pushBlockedByModalTail)
            )
        )
    }

    @Test("FlowEnvironmentStorage isolates dispatchers across hosts")
    @MainActor
    func flowEnvironmentStorageIsolatesDispatchers() {
        let firstStore = FlowStore<FlowHostRoute>()
        let secondStore = FlowStore<FlowHostRoute>()
        let firstStorage = FlowEnvironmentStorage()
        let secondStorage = FlowEnvironmentStorage()

        firstStorage[FlowHostRoute.self] = { firstStore.send($0) }
        secondStorage[FlowHostRoute.self] = { secondStore.send($0) }

        firstStorage[FlowHostRoute.self]?(.push(.landing))
        secondStorage[FlowHostRoute.self]?(.push(.child))

        #expect(firstStore.path == [.push(.landing)])
        #expect(secondStore.path == [.push(.child)])
    }

    @Test("FlowEnvironmentStorage accepts same-store dispatcher refreshes")
    @MainActor
    func flowEnvironmentStorageAcceptsSameStoreDispatcherRefreshes() {
        let store = FlowStore<FlowHostRoute>()
        let storage = FlowEnvironmentStorage()
        let ownerID = ObjectIdentifier(store)

        storage.setIntentDispatcher(
            { store.send($0) },
            ownerID: ownerID,
            routeType: FlowHostRoute.self
        )
        storage.setIntentDispatcher(
            { store.send($0) },
            ownerID: ownerID,
            routeType: FlowHostRoute.self
        )

        storage[FlowHostRoute.self]?(.push(.landing))

        #expect(store.path == [.push(.landing)])
    }
}

private struct UnifiedFlowRouterProbe: View {
    @EnvironmentRouter(FlowHostRoute.self) private var router

    let action: @MainActor (RouterActions<FlowHostRoute>) -> Void

    var body: some View {
        Color.clear.onAppear {
            action(router)
        }
    }
}

private struct RawFlowIntentProbe: View {
    @EnvironmentNavigationIntent(FlowHostRoute.self) private var navigation
    @EnvironmentModalIntent(FlowHostRoute.self) private var modal

    var body: some View {
        Color.clear.onAppear {
            modal(.present(.sheetChild, style: .sheet))
            navigation(.go(.child))
        }
    }
}

#if canImport(AppKit)
@MainActor
@discardableResult
private func renderFlowHost<V: View>(_ view: V) throws -> NSHostingView<V> {
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    return hostingView
}
#else
@MainActor
private func renderFlowHost<V: View>(_ view: V) throws {
    throw Skip("FlowHost environment rendering tests require AppKit.")
}
#endif
