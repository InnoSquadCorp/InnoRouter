// MARK: - FlowHostCompositionTests.swift
// InnoRouterTests - FlowHost composition and environment dispatcher injection
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import SwiftUI
import InnoRouter
@testable import InnoRouterSwiftUI

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
