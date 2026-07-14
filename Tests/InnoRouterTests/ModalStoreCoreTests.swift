// MARK: - ModalStoreCoreTests.swift
// InnoRouter Tests
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
import Observation
import OSLog
import Synchronization
import SwiftUI
import InnoRouter
import InnoRouterEffects
@testable import InnoRouterSwiftUI

// MARK: - ModalStore Tests

@Suite("ModalStore Tests")
struct ModalStoreTests {
    @Test("Initial queued presentations normalize into active and queued state without events")
    @MainActor
    func testInitNormalizesQueuedPresentationsWithoutCallbacks() {
        let presented = Mutex<[ModalPresentation<TestModalRoute>]>([])
        let queueChanges = Mutex<[([ModalPresentation<TestModalRoute>], [ModalPresentation<TestModalRoute>])]>([])
        let first = ModalPresentation<TestModalRoute>(route: .profile, style: .sheet)
        let second = ModalPresentation<TestModalRoute>(route: .onboarding, style: .fullScreenCover)
        let store = ModalStore<TestModalRoute>(
            currentPresentation: nil,
            queuedPresentations: [first, second],
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .presented(let presentation):
                        presented.withLock { $0.append(presentation) }
                    case .queueChanged(let oldQueue, let newQueue):
                        queueChanges.withLock { $0.append((oldQueue, newQueue)) }
                    default:
                        break
                    }
                }
            )
        )

        #expect(store.currentPresentation == first)
        #expect(store.queuedPresentations == [second])
        #expect(presented.withLock { $0.isEmpty })
        #expect(queueChanges.withLock { $0.isEmpty })
    }

    @Test("First present becomes the active modal")
    @MainActor
    func testPresentCreatesActiveModal() {
        let store = ModalStore<TestModalRoute>()

        store.present(.profile, style: .sheet)

        #expect(store.currentPresentation?.route == .profile)
        #expect(store.currentPresentation?.style == .sheet)
        #expect(store.queuedPresentations.isEmpty)
    }

    @Test("Additional presents queue while one is active")
    @MainActor
    func testPresentQueuesWhenActiveModalExists() {
        let store = ModalStore<TestModalRoute>()

        store.present(.profile, style: .sheet)
        store.present(.onboarding, style: .fullScreenCover)

        #expect(store.currentPresentation?.route == .profile)
        #expect(store.queuedPresentations.map(\.route) == [.onboarding])
        #expect(store.queuedPresentations.map(\.style) == [.fullScreenCover])
    }

    @Test("Dismiss current promotes the next queued modal")
    @MainActor
    func testDismissPromotesQueuedPresentation() {
        let store = ModalStore<TestModalRoute>()

        store.present(.profile, style: .sheet)
        store.present(.onboarding, style: .fullScreenCover)
        store.dismissCurrent()

        #expect(store.currentPresentation?.route == .onboarding)
        #expect(store.currentPresentation?.style == .fullScreenCover)
        #expect(store.queuedPresentations.isEmpty)
    }

    @Test("First present emits presented once without queueChanged")
    @MainActor
    func testPresentEmitsPresentedWithoutQueueChanged() {
        let presented = Mutex<[ModalPresentation<TestModalRoute>]>([])
        let queueChanges = Mutex<[([ModalPresentation<TestModalRoute>], [ModalPresentation<TestModalRoute>])]>([])
        let store = ModalStore<TestModalRoute>(
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .presented(let presentation):
                        presented.withLock { $0.append(presentation) }
                    case .queueChanged(let oldQueue, let newQueue):
                        queueChanges.withLock { $0.append((oldQueue, newQueue)) }
                    default:
                        break
                    }
                }
            )
        )

        store.present(.profile, style: .sheet)

        #expect(presented.withLock(\.count) == 1)
        #expect(presented.withLock(\.first)?.route == .profile)
        #expect(queueChanges.withLock { $0.isEmpty })
    }

    @Test("Queued present emits queueChanged but not presented")
    @MainActor
    func testQueuedPresentEmitsQueueCallbackOnly() {
        let presented = Mutex<[ModalPresentation<TestModalRoute>]>([])
        let queueChanges = Mutex<[([ModalPresentation<TestModalRoute>], [ModalPresentation<TestModalRoute>])]>([])
        let store = ModalStore<TestModalRoute>(
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .presented(let presentation):
                        presented.withLock { $0.append(presentation) }
                    case .queueChanged(let oldQueue, let newQueue):
                        queueChanges.withLock { $0.append((oldQueue, newQueue)) }
                    default:
                        break
                    }
                }
            )
        )

        store.present(.profile, style: .sheet)
        store.present(.onboarding, style: .fullScreenCover)

        #expect(presented.withLock(\.count) == 1)
        let change = queueChanges.withLock(\.first)
        #expect(change?.0.isEmpty == true)
        #expect(change?.1.map(\.route) == [.onboarding])
    }

    @Test("Dismiss current emits dismiss reason and promoted presentation")
    @MainActor
    func testDismissCurrentEmitsCallbacksInOrder() {
        let dismissed = Mutex<[(ModalPresentation<TestModalRoute>, ModalDismissalReason)]>([])
        let presented = Mutex<[ModalPresentation<TestModalRoute>]>([])
        let queueChanges = Mutex<[([ModalPresentation<TestModalRoute>], [ModalPresentation<TestModalRoute>])]>([])
        let store = ModalStore<TestModalRoute>(
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .presented(let presentation):
                        presented.withLock { $0.append(presentation) }
                    case .dismissed(let presentation, let reason):
                        dismissed.withLock { $0.append((presentation, reason)) }
                    case .queueChanged(let oldQueue, let newQueue):
                        queueChanges.withLock { $0.append((oldQueue, newQueue)) }
                    default:
                        break
                    }
                }
            )
        )

        store.present(.profile, style: .sheet)
        store.present(.onboarding, style: .fullScreenCover)
        store.dismissCurrent()

        #expect(dismissed.withLock(\.count) == 1)
        #expect(dismissed.withLock(\.first)?.0.route == .profile)
        #expect(dismissed.withLock(\.first)?.1 == .dismiss)
        #expect(queueChanges.withLock(\.count) == 2)
        #expect(queueChanges.withLock { $0.last?.0.map(\.route) } == [.onboarding])
        #expect(queueChanges.withLock { $0.last?.1.isEmpty } == true)
        #expect(presented.withLock(\.count) == 2)
        #expect(presented.withLock(\.last)?.route == .onboarding)
    }

    @Test("Dismiss all clears the active modal and queue")
    @MainActor
    func testDismissAllClearsState() {
        let store = ModalStore<TestModalRoute>()

        store.present(.profile, style: .sheet)
        store.present(.onboarding, style: .fullScreenCover)
        store.dismissAll()

        #expect(store.currentPresentation == nil)
        #expect(store.queuedPresentations.isEmpty)
    }

    @Test("Dismiss all emits active dismiss and queue clear once")
    @MainActor
    func testDismissAllEmitsDismissAndQueueCallbacks() {
        let dismissed = Mutex<[(ModalPresentation<TestModalRoute>, ModalDismissalReason)]>([])
        let queueChanges = Mutex<[([ModalPresentation<TestModalRoute>], [ModalPresentation<TestModalRoute>])]>([])
        let store = ModalStore<TestModalRoute>(
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .dismissed(let presentation, let reason):
                        dismissed.withLock { $0.append((presentation, reason)) }
                    case .queueChanged(let oldQueue, let newQueue):
                        queueChanges.withLock { $0.append((oldQueue, newQueue)) }
                    default:
                        break
                    }
                }
            )
        )

        store.present(.profile, style: .sheet)
        store.present(.onboarding, style: .fullScreenCover)
        store.dismissAll()

        #expect(dismissed.withLock(\.count) == 1)
        #expect(dismissed.withLock(\.first)?.0.route == .profile)
        #expect(dismissed.withLock(\.first)?.1 == .dismissAll)
        #expect(queueChanges.withLock(\.count) == 2)
        #expect(queueChanges.withLock { $0.last?.0.map(\.route) } == [.onboarding])
        #expect(queueChanges.withLock { $0.last?.1.isEmpty } == true)
    }

    @Test("Dismiss all clears state before callbacks so reentrant presents survive")
    @MainActor
    func testDismissAllClearsStateBeforeCallbacks() {
        let callbackOrder = Mutex<[String]>([])
        let observedStateDuringDismiss = Mutex<([TestModalRoute?], [[TestModalRoute]])>(([], []))
        var store: ModalStore<TestModalRoute>!
        store = ModalStore<TestModalRoute>(
            configuration: .init(
                onEvent: { event in
                    switch event {
                    case .dismissed:
                        callbackOrder.withLock { $0.append("dismiss") }
                        observedStateDuringDismiss.withLock {
                            $0.0.append(store.currentPresentation?.route)
                            $0.1.append(store.queuedPresentations.map(\.route))
                        }
                        store.present(.profile, style: .sheet)
                    case .queueChanged:
                        callbackOrder.withLock { $0.append("queue") }
                    default:
                        break
                    }
                }
            )
        )

        store.present(.onboarding, style: .fullScreenCover)
        store.present(.profile, style: .sheet)
        callbackOrder.withLock { $0.removeAll() }

        store.dismissAll()

        #expect(callbackOrder.withLock { $0 } == ["queue", "dismiss"])
        #expect(observedStateDuringDismiss.withLock { $0.0 } == [nil])
        #expect(observedStateDuringDismiss.withLock { $0.1 } == [[]])
        #expect(store.currentPresentation?.route == .profile)
        #expect(store.currentPresentation?.style == .sheet)
        #expect(store.queuedPresentations.isEmpty)
    }

    @Test("Duplicate routes retain unique identities in the queue")
    @MainActor
    func testQueuedDuplicateRoutesKeepUniqueIDs() {
        let store = ModalStore<TestModalRoute>()

        store.present(.profile, style: .sheet)
        store.present(.profile, style: .sheet)
        store.present(.profile, style: .sheet)

        let ids = [store.currentPresentation?.id].compactMap { $0 } + store.queuedPresentations.map(\.id)
        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)
    }

    @Test("Style bindings expose only matching active modal and dismiss through setter")
    @MainActor
    func testBindingsFilterByStyleAndDismissThroughSetter() {
        let store = ModalStore<TestModalRoute>()

        store.send(.present(.profile, style: .sheet))
        store.send(.present(.onboarding, style: .fullScreenCover))

        #expect(store.binding(for: .sheet).wrappedValue?.route == .profile)
        #expect(store.binding(for: .fullScreenCover).wrappedValue == nil)

        store.binding(for: .sheet).wrappedValue = nil

        #expect(store.currentPresentation?.route == .onboarding)
        #expect(store.currentPresentation?.style == .fullScreenCover)
        #expect(store.binding(for: .sheet).wrappedValue == nil)
        #expect(store.binding(for: .fullScreenCover).wrappedValue?.route == .onboarding)
    }

    @Test("Binding setter dismiss uses systemDismiss reason")
    @MainActor
    func testBindingSetterUsesSystemDismissReason() {
        let dismissed = Mutex<[(ModalPresentation<TestModalRoute>, ModalDismissalReason)]>([])
        let store = ModalStore<TestModalRoute>(
            configuration: .init(
                onEvent: { event in
                    guard case .dismissed(let presentation, let reason) = event else { return }
                    dismissed.withLock { $0.append((presentation, reason)) }
                }
            )
        )

        store.send(.present(.profile, style: .sheet))
        store.binding(for: .sheet).wrappedValue = nil

        #expect(dismissed.withLock(\.count) == 1)
        #expect(dismissed.withLock(\.first)?.0.route == .profile)
        #expect(dismissed.withLock(\.first)?.1 == .systemDismiss)
    }

    @Test("Telemetry recorder receives modal lifecycle events in order")
    @MainActor
    func testModalTelemetryRecorderLifecycle() {
        let recorder = Mutex<[ModalStoreTelemetryEvent<TestModalRoute>]>([])
        let store = ModalStore<TestModalRoute>(
            configuration: .init(
                logger: Logger(subsystem: "InnoRouterTests", category: "ModalStore")
            ),
            telemetryRecorder: { event in
                recorder.withLock { $0.append(event) }
            }
        )

        store.present(.profile, style: .sheet)
        store.present(.onboarding, style: .fullScreenCover)
        store.dismissCurrent()
        store.dismissAll()

        let events = recorder.withLock { $0 }.filter { event in
            if case .commandIntercepted = event { return false }
            if case .middlewareMutation = event { return false }
            return true
        }
        #expect(events.count == 7)

        switch events[0] {
        case .presented(let presentation):
            #expect(presentation.route == .profile)
            #expect(presentation.style == .sheet)
        default:
            Issue.record("Expected presented event first")
        }

        switch events[1] {
        case .queued(let presentation):
            #expect(presentation.route == .onboarding)
            #expect(presentation.style == .fullScreenCover)
        default:
            Issue.record("Expected queued event second")
        }

        switch events[2] {
        case .queueChanged(let oldQueue, let newQueue):
            #expect(oldQueue.isEmpty)
            #expect(newQueue.map(\.route) == [.onboarding])
        default:
            Issue.record("Expected queueChanged event third")
        }

        switch events[3] {
        case .dismissed(let presentation, let reason):
            #expect(presentation.route == .profile)
            #expect(reason == .dismiss)
        default:
            Issue.record("Expected dismissed event fourth")
        }

        switch events[4] {
        case .queueChanged(let oldQueue, let newQueue):
            #expect(oldQueue.map(\.route) == [.onboarding])
            #expect(newQueue.isEmpty)
        default:
            Issue.record("Expected queueChanged promotion event fifth")
        }

        switch events[5] {
        case .presented(let presentation):
            #expect(presentation.route == .onboarding)
            #expect(presentation.style == .fullScreenCover)
        default:
            Issue.record("Expected promoted presented event sixth")
        }

        switch events[6] {
        case .dismissed(let presentation, let reason):
            #expect(presentation.route == .onboarding)
            #expect(reason == .dismissAll)
        default:
            Issue.record("Expected dismissAll event seventh")
        }
    }

    @Test("Telemetry recorder captures replaceCurrent as replacement before command intercept")
    @MainActor
    func testModalTelemetryRecorderReplaceCurrent() {
        let recorder = Mutex<[ModalStoreTelemetryEvent<TestBoundModalRoute>]>([])
        let store = ModalStore<TestBoundModalRoute>(
            configuration: .init(
                logger: Logger(subsystem: "InnoRouterTests", category: "ModalStore")
            ),
            telemetryRecorder: { event in
                recorder.withLock { $0.append(event) }
            }
        )

        store.present(.profile(id: "42"), style: .sheet)
        recorder.withLock { $0.removeAll() }

        store.replaceCurrent(.profile(id: "99"), style: .sheet)

        let events = recorder.withLock { $0 }
        #expect(events.count == 2)

        guard case .replaced(let old, let new) = events[0] else {
            Issue.record("Expected replaceCurrent to emit a replaced event first")
            return
        }
        #expect(old.route == .profile(id: "42"))
        #expect(new.route == .profile(id: "99"))

        guard case .commandIntercepted(let command, let outcome, let cancellationReason) = events[1] else {
            Issue.record("Expected replaceCurrent to emit commandIntercepted second")
            return
        }

        #expect(outcome == .executed)
        #expect(cancellationReason == nil)
        guard case .replaceCurrent(let presentation) = command else {
            Issue.record("Expected replaceCurrent command, got \(command)")
            return
        }
        #expect(presentation.route == .profile(id: "99"))
        #expect(presentation.style == .sheet)
    }
}
