// MARK: - NavigationStoreMiddlewareObservabilityTests.swift
// InnoRouterTests - Public middleware mutation observation hook
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

// MARK: - Local fixtures

private enum ObsRoute: Route {
    case a
    case b
}

@MainActor
private func noopMiddleware() -> AnyNavigationMiddleware<ObsRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in .proceed(command) })
}

// MARK: - Suite

@Suite("NavigationStore Middleware Observability Tests")
struct NavigationStoreMiddlewareObservabilityTests {

    @Test("onEvent emits middlewareMutation for each successful mutator call")
    @MainActor
    func middlewareMutationEventFiresForEachMutator() {
        let events = Mutex<[MiddlewareMutationEvent<ObsRoute>]>([])
        let store = NavigationStore<ObsRoute>(
            configuration: NavigationStoreConfiguration<ObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        let first = store.addMiddleware(noopMiddleware(), debugName: "first")
        let second = store.insertMiddleware(noopMiddleware(), at: 0, debugName: "second")
        _ = store.replaceMiddleware(first, with: noopMiddleware(), debugName: "first-replaced")
        #expect(store.moveMiddleware(second, to: 1))
        _ = store.removeMiddleware(first)

        let captured = events.withLock { $0 }
        let actions = captured.map(\.action)
        #expect(actions == [.added, .inserted, .replaced, .moved, .removed])
    }

    @Test("onEvent never emits middlewareMutation for invalid mutations")
    @MainActor
    func middlewareMutationEventDoesNotFireForInvalidMutations() {
        let events = Mutex<[MiddlewareMutationEvent<ObsRoute>]>([])
        let store = NavigationStore<ObsRoute>(
            configuration: NavigationStoreConfiguration<ObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        let stranger = NavigationMiddlewareHandle()
        #expect(store.removeMiddleware(stranger) == nil)
        #expect(store.replaceMiddleware(stranger, with: noopMiddleware()) == false)
        #expect(store.moveMiddleware(stranger, to: 0) == false)

        let captured = events.withLock { $0 }
        #expect(captured.isEmpty)
    }

    @Test("event payload carries the mutated handle and debug name")
    @MainActor
    func eventPayloadContainsHandleAndDebugName() {
        let events = Mutex<[MiddlewareMutationEvent<ObsRoute>]>([])
        let store = NavigationStore<ObsRoute>(
            configuration: NavigationStoreConfiguration<ObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        let handle = store.addMiddleware(noopMiddleware(), debugName: "analytics")

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
        let events = Mutex<[MiddlewareMutationEvent<ObsRoute>]>([])
        let store = NavigationStore<ObsRoute>(
            configuration: NavigationStoreConfiguration<ObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    events.withLock { $0.append(mutation) }
                }
            )
        )

        _ = store.addMiddleware(noopMiddleware())
        _ = store.insertMiddleware(noopMiddleware(), at: -10, debugName: "head")
        let tail = store.addMiddleware(noopMiddleware(), debugName: "tail")
        _ = store.moveMiddleware(tail, to: 99)

        let captured = events.withLock { $0 }
        // Order: added(0), inserted(0 clamped), added(2), moved(2 clamped to count-1).
        let indexes = captured.map(\.index)
        #expect(indexes == [0, 0, 2, 2])
    }

    @Test("internal telemetry recorder and public callback both receive middleware mutations")
    @MainActor
    func internalTelemetryRecorderAndPublicCallbackBothReceiveMutations() {
        let internalEvents = Mutex<[NavigationStoreTelemetryEvent<ObsRoute>]>([])
        let publicEvents = Mutex<[MiddlewareMutationEvent<ObsRoute>]>([])
        let store = NavigationStore<ObsRoute>(
            configuration: NavigationStoreConfiguration<ObsRoute>(
                onEvent: { event in
                    guard case .middlewareMutation(let mutation) = event else { return }
                    publicEvents.withLock { $0.append(mutation) }
                }
            ),
            nonPrefixAssertionHandler: { _, _ in },
            telemetryRecorder: { event in
                internalEvents.withLock { $0.append(event) }
            }
        )

        let handle = store.addMiddleware(noopMiddleware(), debugName: "combined")

        let telemetry = internalEvents.withLock { $0 }
        #expect(telemetry.count == 1)
        guard case .middlewareMutation(let action, let metadata, let index) = telemetry[0] else {
            Issue.record("Expected middleware mutation telemetry event")
            return
        }
        #expect(action == .added)
        #expect(metadata.handle == handle)
        #expect(metadata.debugName == "combined")
        #expect(index == 0)

        let published = publicEvents.withLock { $0 }
        #expect(published.count == 1)
        let event = published[0]
        #expect(event.action == .added)
        #expect(event.metadata.handle == handle)
        #expect(event.metadata.debugName == "combined")
        #expect(event.index == 0)
    }
}
