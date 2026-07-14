// MARK: - FlowIntentModalAwareVariantsTests.swift
// InnoRouterTests - .backOrPushDismissingModal / .pushUniqueRootDismissingModal
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

private enum MARoute: Route {
    case home
    case detail
    case settings
    case sheet
    case queuedSheet
}

@MainActor
private final class PartialRejectionReentryObserver {
    weak var store: FlowStore<MARoute>?
    var events: [FlowEvent<MARoute>] = []
    private var didReenter = false

    func handle(_ event: FlowEvent<MARoute>) {
        events.append(event)
        guard !didReenter, case .modal(.dismissed) = event else { return }
        didReenter = true
        store?.send(.presentSheet(.queuedSheet))
    }
}

@Suite("FlowIntent Modal-Aware Variant Tests")
struct FlowIntentModalAwareVariantsTests {

    @Test(".backOrPushDismissingModal with active modal dismisses then pops to existing route")
    @MainActor
    func backOrPushDismissingExisting() {
        let store = FlowStore<MARoute>()
        store.send(.push(.home))
        store.send(.push(.detail))
        store.send(.presentSheet(.sheet))

        store.send(.backOrPushDismissingModal(.home))

        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.navigationStore.state.path == [.home])
    }

    @Test(".backOrPushDismissingModal with active modal dismisses then pushes new route")
    @MainActor
    func backOrPushDismissingNew() {
        let store = FlowStore<MARoute>()
        store.send(.push(.home))
        store.send(.presentSheet(.sheet))

        store.send(.backOrPushDismissingModal(.detail))

        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.navigationStore.state.path == [.home, .detail])
    }

    @Test("reentrant send waits until partial commit rejection and coalescing finish")
    @MainActor
    func reentrantSendWaitsForPartialRejectionBoundary() throws {
        let observer = PartialRejectionReentryObserver()
        let gate = AnyNavigationMiddleware<MARoute>(
            willExecute: { command, _ in
                if case .push(.detail) = command {
                    return .cancel(.middleware(debugName: "detail-gate", command: command))
                }
                return .proceed(command)
            }
        )
        let store = FlowStore<MARoute>(
            configuration: .init(
                navigation: .init(
                    middlewares: [.init(middleware: gate, debugName: "detail-gate")]
                ),
                onEvent: { event in
                    observer.handle(event)
                },
                queueCoalescePolicy: .dropQueued
            )
        )
        observer.store = store
        store.send(.push(.home))
        store.send(.presentSheet(.sheet))
        observer.events.removeAll()

        store.send(.backOrPushDismissingModal(.detail))

        #expect(store.navigationStore.state.path == [.home])
        #expect(store.modalStore.currentPresentation?.route == .queuedSheet)
        #expect(store.path == [.push(.home), .sheet(.queuedSheet)])

        let rejectionIndex = try #require(observer.events.firstIndex { event in
            if case .intentRejected(
                .backOrPushDismissingModal(.detail),
                .middlewareRejected(debugName: "detail-gate")
            ) = event {
                return true
            }
            return false
        })
        let reentrantPresentationIndex = try #require(observer.events.firstIndex { event in
            if case .modal(.presented(let presentation)) = event {
                return presentation.route == .queuedSheet
            }
            return false
        })
        #expect(rejectionIndex < reentrantPresentationIndex)
    }

    @Test(".backOrPushDismissingModal with no modal behaves exactly like .backOrPush")
    @MainActor
    func backOrPushDismissingNoModal() {
        let store = FlowStore<MARoute>()
        store.send(.push(.home))
        store.send(.push(.detail))

        store.send(.backOrPushDismissingModal(.home))

        #expect(store.navigationStore.state.path == [.home])
    }

    @Test(".pushUniqueRootDismissingModal dismisses modal then pushes missing route")
    @MainActor
    func pushUniqueRootDismissingNew() {
        let store = FlowStore<MARoute>()
        store.send(.presentSheet(.sheet))

        store.send(.pushUniqueRootDismissingModal(.home))

        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.navigationStore.state.path == [.home])
    }

    @Test(".pushUniqueRootDismissingModal silent no-op on stack side when route already present")
    @MainActor
    func pushUniqueRootDismissingExisting() {
        let store = FlowStore<MARoute>()
        store.send(.push(.home))
        store.send(.presentSheet(.sheet))

        store.send(.pushUniqueRootDismissingModal(.home))

        // Modal dismissed; stack unchanged because .home already present.
        #expect(store.modalStore.currentPresentation == nil)
        #expect(store.navigationStore.state.path == [.home])
    }

    @Test(".backOrPushDismissingModal stops when a queued modal is promoted")
    @MainActor
    func backOrPushDismissingQueuedModalPromotion() throws {
        var rejections: [(FlowIntent<MARoute>, FlowRejectionReason)] = []
        let store = FlowStore<MARoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.append((intent, reason))
                }
            )
        )
        store.send(.push(.home))
        store.send(.presentSheet(.sheet))
        store.send(.presentSheet(.queuedSheet))

        store.send(.backOrPushDismissingModal(.detail))

        #expect(store.modalStore.currentPresentation?.route == .queuedSheet)
        #expect(store.modalStore.queuedPresentations.isEmpty)
        #expect(store.navigationStore.state.path == [.home])
        let rejection = try #require(rejections.first)
        #expect(rejection.0 == .backOrPushDismissingModal(.detail))
        #expect(rejection.1 == .pushBlockedByModalTail)
    }

    @Test(".pushUniqueRootDismissingModal stops when a queued modal is promoted")
    @MainActor
    func pushUniqueRootDismissingQueuedModalPromotion() throws {
        var rejections: [(FlowIntent<MARoute>, FlowRejectionReason)] = []
        let store = FlowStore<MARoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.append((intent, reason))
                }
            )
        )
        store.send(.presentSheet(.sheet))
        store.send(.presentSheet(.queuedSheet))

        store.send(.pushUniqueRootDismissingModal(.home))

        #expect(store.modalStore.currentPresentation?.route == .queuedSheet)
        #expect(store.modalStore.queuedPresentations.isEmpty)
        #expect(store.navigationStore.state.path.isEmpty)
        let rejection = try #require(rejections.first)
        #expect(rejection.0 == .pushUniqueRootDismissingModal(.home))
        #expect(rejection.1 == .pushBlockedByModalTail)
    }
}
