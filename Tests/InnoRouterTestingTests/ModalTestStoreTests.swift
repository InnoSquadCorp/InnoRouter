// MARK: - ModalTestStoreTests.swift
// InnoRouterTestingTests - ModalTestStore behavior
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterTesting

private enum ModalRoute: Route {
    case onboarding
    case profile
    case blocked
}

@MainActor
private func passthroughModalMiddleware() -> AnyModalMiddleware<ModalRoute> {
    AnyModalMiddleware(willExecute: { command, _, _ in .proceed(command) })
}

@MainActor
private func blockPresentMiddleware() -> AnyModalMiddleware<ModalRoute> {
    AnyModalMiddleware(willExecute: { command, _, _ in
        if case .present = command {
            return .cancel(.conditionFailed)
        }
        return .proceed(command)
    })
}

@Suite("ModalTestStore Tests")
struct ModalTestStoreTests {

    @Test("present emits .presented first, then .commandIntercepted")
    @MainActor
    func presentEmitsPresentedThenIntercept() {
        let store = ModalTestStore<ModalRoute>()

        store.present(.onboarding, style: .sheet)

        // ModalStore.applyCommand emits .presented BEFORE .commandIntercepted.
        store.receivePresented(.onboarding)
        store.receiveIntercepted { command, result in
            if case .present = command,
               case .executed = result { return true }
            return false
        }
        store.finish()
    }

    @Test("dismissCurrent with queued emits dismissed → queueChanged → presented → intercept")
    @MainActor
    func dismissCurrentWithQueueEmitsPromotion() {
        let store = ModalTestStore<ModalRoute>()

        store.present(.onboarding, style: .sheet)
        store.present(.profile, style: .sheet) // queued
        store.skipReceivedEvents()

        store.dismissCurrent()

        // Emission order: applyDismissCurrent → .dismissed → promoteNextPresentationIfNeeded
        // (.queueChanged + .presented) → finally .commandIntercepted.
        store.receiveDismissed { presentation, reason in
            presentation.route == .onboarding && reason == .dismiss
        }
        store.receiveQueueChanged { old, new in
            old.map(\.route) == [.profile] && new.isEmpty
        }
        store.receivePresented(.profile)
        store.receiveIntercepted { _, result in
            if case .executed = result { return true }
            return false
        }
        store.finish()
    }

    @Test("middleware cancel emits a single .commandIntercepted(.cancelled) and no .presented")
    @MainActor
    func middlewareCancelEmitsCancelledOnly() {
        let store = ModalTestStore<ModalRoute>(
            configuration: ModalStoreConfiguration(
                middlewares: [ModalMiddlewareRegistration(middleware: blockPresentMiddleware(), debugName: "block")]
            )
        )

        store.present(.blocked, style: .sheet)

        // Cancelled path never touches applyCommand, so only .commandIntercepted fires.
        store.receiveIntercepted { _, result in
            if case .cancelled = result { return true }
            return false
        }
        #expect(store.currentPresentation == nil)
        store.finish()
    }

    @Test("middleware mutation emits .middlewareMutation")
    @MainActor
    func middlewareMutationEmitted() {
        let store = ModalTestStore<ModalRoute>()

        _ = store.store.addMiddleware(passthroughModalMiddleware(), debugName: "noop")

        store.receiveMiddlewareMutation(action: .added)
        store.finish()
    }
}
