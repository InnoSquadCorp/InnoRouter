// MARK: - ModalStoreMiddlewareObservabilityTests.swift
// InnoRouterTests - Public modal middleware mutation observation hook
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

// MARK: - Local fixtures

private enum ModalObsRoute: Route {
    case a
    case b
}

@MainActor
private func noopModalMiddleware() -> AnyModalMiddleware<ModalObsRoute> {
    AnyModalMiddleware(willExecute: { command, _, _ in .proceed(command) })
}

// MARK: - Suite

@Suite("ModalStore Middleware Observability Tests")
struct ModalStoreMiddlewareObservabilityTests {

    @Test("onEvent emits middlewareMutation for each successful mutator call")
    @MainActor
    func middlewareMutationEventFiresForEachMutator() {
        let events = Mutex<[ModalMiddlewareMutationEvent<ModalObsRoute>]>([])
        let store = ModalStore<ModalObsRoute>(
            configuration: ModalStoreConfiguration<ModalObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        let first = store.addMiddleware(noopModalMiddleware(), debugName: "first")
        let second = store.insertMiddleware(noopModalMiddleware(), at: 0, debugName: "second")
        _ = store.replaceMiddleware(first, with: noopModalMiddleware(), debugName: "first-replaced")
        #expect(store.moveMiddleware(second, to: 1))
        _ = store.removeMiddleware(first)

        let captured = events.withLock { $0 }
        let actions = captured.map(\.action)
        #expect(actions == [.added, .inserted, .replaced, .moved, .removed])
    }

    @Test("onEvent never emits middlewareMutation for invalid mutations")
    @MainActor
    func middlewareMutationEventDoesNotFireForInvalidMutations() {
        let events = Mutex<[ModalMiddlewareMutationEvent<ModalObsRoute>]>([])
        let store = ModalStore<ModalObsRoute>(
            configuration: ModalStoreConfiguration<ModalObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        let stranger = ModalMiddlewareHandle()
        #expect(store.removeMiddleware(stranger) == nil)
        #expect(store.replaceMiddleware(stranger, with: noopModalMiddleware()) == false)
        #expect(store.moveMiddleware(stranger, to: 0) == false)

        let captured = events.withLock { $0 }
        #expect(captured.isEmpty)
    }

    @Test("event payload carries the mutated handle and debug name")
    @MainActor
    func eventPayloadContainsHandleAndDebugName() {
        let events = Mutex<[ModalMiddlewareMutationEvent<ModalObsRoute>]>([])
        let store = ModalStore<ModalObsRoute>(
            configuration: ModalStoreConfiguration<ModalObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        let handle = store.addMiddleware(noopModalMiddleware(), debugName: "analytics")

        let captured = events.withLock { $0 }
        #expect(captured.count == 1)
        let event = captured[0]
        #expect(event.action == .added)
        #expect(event.metadata.handle == handle)
        #expect(event.metadata.debugName == "analytics")
        #expect(event.index == 0)
    }

    @Test("event index reflects clamping for insert and move")
    @MainActor
    func eventIndexReflectsClamping() {
        let events = Mutex<[ModalMiddlewareMutationEvent<ModalObsRoute>]>([])
        let store = ModalStore<ModalObsRoute>(
            configuration: ModalStoreConfiguration<ModalObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        _ = store.addMiddleware(noopModalMiddleware())
        _ = store.insertMiddleware(noopModalMiddleware(), at: -10, debugName: "head")
        let tail = store.addMiddleware(noopModalMiddleware(), debugName: "tail")
        _ = store.moveMiddleware(tail, to: 99)

        let captured = events.withLock { $0 }
        let indexes = captured.map(\.index)
        #expect(indexes == [0, 0, 2, 2])
    }

    @Test("internal telemetry recorder and public callback both receive middleware mutations")
    @MainActor
    func internalTelemetryRecorderAndPublicCallbackBothReceiveMutations() {
        let internalEvents = Mutex<[ModalStoreTelemetryEvent<ModalObsRoute>]>([])
        let publicEvents = Mutex<[ModalMiddlewareMutationEvent<ModalObsRoute>]>([])
        let store = ModalStore<ModalObsRoute>(
            configuration: ModalStoreConfiguration<ModalObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    publicEvents.withLock { $0.append(mutation) }
                }
            ),
            telemetryRecorder: { event in
                internalEvents.withLock { $0.append(event) }
            }
        )

        let handle = store.addMiddleware(noopModalMiddleware(), debugName: "combined")

        let telemetry = internalEvents.withLock { $0 }
        let mutations = telemetry.compactMap { event -> (
            ModalStoreTelemetryEvent<ModalObsRoute>.MiddlewareMutation,
            ModalMiddlewareMetadata,
            Int?
        )? in
            if case .middlewareMutation(let action, let metadata, let index) = event {
                return (action, metadata, index)
            }
            return nil
        }

        #expect(mutations.count == 1)
        guard let first = mutations.first else { return }
        #expect(first.0 == .added)
        #expect(first.1.handle == handle)
        #expect(first.1.debugName == "combined")
        #expect(first.2 == 0)

        let published = publicEvents.withLock { $0 }
        #expect(published.count == 1)
        let event = published[0]
        #expect(event.action == .added)
        #expect(event.metadata.handle == handle)
        #expect(event.metadata.debugName == "combined")
        #expect(event.index == 0)
    }
}
