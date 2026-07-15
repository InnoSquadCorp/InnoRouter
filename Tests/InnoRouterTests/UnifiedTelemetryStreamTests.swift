// MARK: - UnifiedTelemetryStreamTests.swift
// InnoRouterTests - store.events AsyncStream coverage
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

private enum StreamRoute: Route {
    case home
    case detail
    case sheet
    case settings
}

@MainActor
private final class WeakStoreReference<Value: AnyObject> {
    weak var value: Value?
}

@MainActor
private func noopNavMiddleware() -> AnyNavigationMiddleware<StreamRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in .proceed(command) })
}

@Suite("Unified Telemetry Stream Tests")
struct UnifiedTelemetryStreamTests {

    // MARK: - NavigationStore

    @Test("NavigationStore.events emits .changed for a single push")
    @MainActor
    func navigationEventsEmitsChangedOnPush() async {
        let store = NavigationStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        store.send(.go(.home))

        let first = await iterator.next()
        guard case .changed(let from, let to) = first else {
            Issue.record("Expected .changed, got \(String(describing: first))")
            return
        }
        #expect(from.path.isEmpty)
        #expect(to.path == [.home])
    }

    @Test("Capturing events before its task preserves an immediate first event")
    @MainActor
    func preCapturedNavigationEventsPreserveImmediateEvent() async {
        let store = NavigationStore<StreamRoute>()
        let events = store.events
        let receiveTask = Task { @MainActor in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        // The child task cannot run on MainActor until this method suspends.
        // Capturing `events` first must therefore buffer this immediate send.
        store.send(.go(.home))

        guard case .changed(_, let to) = await receiveTask.value else {
            Issue.record("Expected the pre-captured stream to preserve .changed")
            return
        }
        #expect(to.path == [.home])
    }

    @Test("NavigationStore.events emits .batchExecuted alongside a coalesced .changed")
    @MainActor
    func navigationEventsEmitsBatchExecuted() async {
        let store = NavigationStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        _ = store.executeBatch([.push(.home), .push(.detail)])

        // Order: one coalesced .changed, then the .batchExecuted summary.
        let first = await iterator.next()
        let second = await iterator.next()
        guard case .changed = first else {
            Issue.record("Expected .changed, got \(String(describing: first))")
            return
        }
        guard case .batchExecuted(let result) = second else {
            Issue.record("Expected .batchExecuted, got \(String(describing: second))")
            return
        }
        #expect(result.executedCommands.count == 2)
    }

    @Test("NavigationStore.events emits .transactionExecuted on commit")
    @MainActor
    func navigationEventsEmitsTransactionExecuted() async {
        let store = NavigationStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        _ = store.executeTransaction([.push(.home)])

        _ = await iterator.next() // .changed
        let second = await iterator.next()
        guard case .transactionExecuted(let result) = second else {
            Issue.record("Expected .transactionExecuted, got \(String(describing: second))")
            return
        }
        #expect(result.isCommitted)
    }

    @Test("NavigationStore.events emits .middlewareMutation when middleware is added")
    @MainActor
    func navigationEventsEmitsMiddlewareMutation() async {
        let store = NavigationStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        _ = store.addMiddleware(noopNavMiddleware(), debugName: "added")

        let event = await iterator.next()
        guard case .middlewareMutation(let mutation) = event else {
            Issue.record("Expected .middlewareMutation, got \(String(describing: event))")
            return
        }
        #expect(mutation.action == .added)
    }

    @Test("NavigationStore.events emits .pathMismatch on non-prefix rewrite")
    @MainActor
    func navigationEventsEmitsPathMismatch() async {
        let store = NavigationStore<StreamRoute>()
        store.send(.go(.home))

        // Drain the initial .changed.
        var iterator = store.events.makeAsyncIterator()

        store.pathBinding.wrappedValue = [.detail]

        let first = await iterator.next()
        guard case .pathMismatch(let event) = first else {
            Issue.record("Expected .pathMismatch, got \(String(describing: first))")
            return
        }
        #expect(event.oldPath == [.home])
        #expect(event.newPath == [.detail])
    }

    @Test("NavigationStore.events supports multiple independent subscribers")
    @MainActor
    func navigationEventsSupportsMultipleSubscribers() async {
        let store = NavigationStore<StreamRoute>()
        var iteratorA = store.events.makeAsyncIterator()
        var iteratorB = store.events.makeAsyncIterator()

        store.send(.go(.home))

        let eventA = await iteratorA.next()
        let eventB = await iteratorB.next()

        guard case .changed(_, let toA) = eventA, case .changed(_, let toB) = eventB else {
            Issue.record("Expected both subscribers to see .changed")
            return
        }
        #expect(toA.path == [.home])
        #expect(toB.path == [.home])
    }

    @Test("NavigationStore.events coexists with configuration onEvent observer")
    @MainActor
    func navigationEventsCoexistsWithCallback() async {
        let captured = Mutex<[RouteStack<StreamRoute>]>([])
        let store = NavigationStore<StreamRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    guard case .changed(_, let new) = event else { return }
                    captured.withLock { $0.append(new) }
                }
            )
        )
        var iterator = store.events.makeAsyncIterator()

        store.send(.go(.home))

        _ = await iterator.next()

        let callbackPaths = captured.withLock { $0.map(\.path) }
        #expect(callbackPaths == [[.home]])
    }

    @Test("NavigationStore onEvent receives every event kind in events stream order")
    @MainActor
    func navigationOnEventMatchesStreamForEveryEventKind() async {
        let observed = Mutex<[NavigationEvent<StreamRoute>]>([])
        let store = NavigationStore<StreamRoute>(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    observed.withLock { $0.append(event) }
                }
            )
        )
        var iterator = store.events.makeAsyncIterator()

        _ = store.addMiddleware(noopNavMiddleware(), debugName: "observer-coverage")
        store.send(.go(.home))
        _ = store.executeBatch([.push(.detail)])
        _ = store.executeTransaction([.push(.settings)])
        store.pathBinding.wrappedValue = [.detail]

        let callbackEvents = observed.withLock { $0 }
        var streamEvents: [NavigationEvent<StreamRoute>] = []
        for _ in callbackEvents.indices {
            guard let event = await iterator.next() else {
                Issue.record("NavigationStore.events ended before matching onEvent")
                return
            }
            streamEvents.append(event)
        }

        #expect(callbackEvents == streamEvents)
        #expect(callbackEvents.contains { if case .changed = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .batchExecuted = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .transactionExecuted = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .middlewareMutation = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .pathMismatch = $0 { true } else { false } })
    }

    @Test("NavigationStore serializes reentrant observation fan-out")
    @MainActor
    func navigationObservationFanOutIsReentrantSafe() async {
        let callbackEvents = Mutex<[NavigationEvent<StreamRoute>]>([])
        let hasReentered = Mutex(false)
        let storeReference = WeakStoreReference<NavigationStore<StreamRoute>>()
        let store = NavigationStore(
            configuration: NavigationStoreConfiguration(
                onEvent: { event in
                    callbackEvents.withLock { $0.append(event) }
                    guard case .changed(_, let newState) = event,
                          newState.path == [.home]
                    else { return }

                    let shouldReenter = hasReentered.withLock { hasReentered in
                        guard !hasReentered else { return false }
                        hasReentered = true
                        return true
                    }
                    if shouldReenter {
                        _ = storeReference.value?.execute(.push(.detail))
                    }
                }
            )
        )
        storeReference.value = store
        var iterator = store.events.makeAsyncIterator()

        _ = store.execute(.push(.home))

        let callbacks = callbackEvents.withLock { $0 }
        var streamed: [NavigationEvent<StreamRoute>] = []
        for _ in callbacks.indices {
            guard let event = await iterator.next() else {
                Issue.record("NavigationStore.events ended during reentrant fan-out")
                return
            }
            streamed.append(event)
        }

        #expect(store.state.path == [.home, .detail])
        #expect(callbacks.count == 2)
        #expect(callbacks == streamed)
    }

    // MARK: - ModalStore

    @Test("ModalStore.events emits .presented for a single sheet")
    @MainActor
    func modalEventsEmitsPresented() async {
        let store = ModalStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        store.present(.sheet, style: .sheet)

        let first = await iterator.next()
        guard case .presented(let presentation) = first else {
            Issue.record("Expected .presented, got \(String(describing: first))")
            return
        }
        #expect(presentation.route == .sheet)
    }

    @Test("ModalStore.events emits .commandIntercepted for every execute")
    @MainActor
    func modalEventsEmitsCommandIntercepted() async {
        let store = ModalStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        store.present(.sheet, style: .sheet)

        _ = await iterator.next() // .presented
        let second = await iterator.next()
        guard case .commandIntercepted(_, let result) = second else {
            Issue.record("Expected .commandIntercepted, got \(String(describing: second))")
            return
        }
        if case .executed = result { /* ok */ } else {
            Issue.record("Expected .executed result, got \(result)")
        }
    }

    @Test("ModalStore.events emits .replaced before .commandIntercepted")
    @MainActor
    func modalEventsEmitsReplacementSequence() async {
        let store = ModalStore<StreamRoute>()
        store.present(.sheet, style: .sheet)

        var iterator = store.events.makeAsyncIterator()

        store.replaceCurrent(.settings, style: .sheet)

        let first = await iterator.next()
        guard case .replaced(let old, let new) = first else {
            Issue.record("Expected .replaced first, got \(String(describing: first))")
            return
        }
        #expect(old.route == .sheet)
        #expect(new.route == .settings)

        let second = await iterator.next()
        guard case .commandIntercepted(_, let result) = second else {
            Issue.record("Expected .commandIntercepted second, got \(String(describing: second))")
            return
        }
        guard case .executed(.replaceCurrent(let presentation)) = result else {
            Issue.record("Expected .executed(.replaceCurrent), got \(result)")
            return
        }
        #expect(presentation.route == .settings)
    }

    @Test("ModalStore.events emits .dismissed and promoted .queueChanged + .presented")
    @MainActor
    func modalEventsEmitsPromotionSequence() async {
        let store = ModalStore<StreamRoute>()
        store.present(.sheet, style: .sheet)
        store.present(.settings, style: .sheet) // queued

        var iterator = store.events.makeAsyncIterator()

        store.dismissCurrent()

        // Order: dismissed → queueChanged (queue drained) → presented (promoted) → commandIntercepted.
        let first = await iterator.next()
        guard case .dismissed(let dismissed, let reason) = first else {
            Issue.record("Expected .dismissed first, got \(String(describing: first))")
            return
        }
        #expect(dismissed.route == .sheet)
        #expect(reason == .dismiss)

        _ = await iterator.next() // .queueChanged
        let third = await iterator.next()
        guard case .presented(let promoted) = third else {
            Issue.record("Expected .presented (promoted), got \(String(describing: third))")
            return
        }
        #expect(promoted.route == .settings)
    }

    @Test("ModalStore onEvent receives every event kind in events stream order")
    @MainActor
    func modalOnEventMatchesStreamForEveryEventKind() async {
        let observed = Mutex<[ModalEvent<StreamRoute>]>([])
        let store = ModalStore<StreamRoute>(
            configuration: ModalStoreConfiguration(
                onEvent: { event in
                    observed.withLock { $0.append(event) }
                }
            )
        )
        var iterator = store.events.makeAsyncIterator()

        _ = store.addMiddleware(
            AnyModalMiddleware(willExecute: { command, _, _ in .proceed(command) }),
            debugName: "observer-coverage"
        )
        store.present(.sheet, style: .sheet)
        store.present(.detail, style: .sheet)
        store.replaceCurrent(.settings, style: .fullScreenCover)
        store.dismissCurrent()

        let callbackEvents = observed.withLock { $0 }
        var streamEvents: [ModalEvent<StreamRoute>] = []
        for _ in callbackEvents.indices {
            guard let event = await iterator.next() else {
                Issue.record("ModalStore.events ended before matching onEvent")
                return
            }
            streamEvents.append(event)
        }

        #expect(callbackEvents == streamEvents)
        #expect(callbackEvents.contains { if case .presented = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .dismissed = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .replaced = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .queueChanged = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .middlewareMutation = $0 { true } else { false } })
        #expect(callbackEvents.contains { if case .commandIntercepted = $0 { true } else { false } })
    }

    @Test("ModalStore serializes reentrant observation fan-out")
    @MainActor
    func modalObservationFanOutIsReentrantSafe() async {
        let callbackEvents = Mutex<[ModalEvent<StreamRoute>]>([])
        let hasReentered = Mutex(false)
        let storeReference = WeakStoreReference<ModalStore<StreamRoute>>()
        let store = ModalStore(
            configuration: ModalStoreConfiguration(
                onEvent: { event in
                    callbackEvents.withLock { $0.append(event) }
                    guard case .dismissed = event else { return }

                    let shouldReenter = hasReentered.withLock { hasReentered in
                        guard !hasReentered else { return false }
                        hasReentered = true
                        return true
                    }
                    if shouldReenter {
                        storeReference.value?.present(.settings, style: .sheet)
                    }
                }
            )
        )
        storeReference.value = store
        store.present(.sheet, style: .sheet)
        store.present(.detail, style: .sheet)
        callbackEvents.withLock { $0.removeAll() }
        var iterator = store.events.makeAsyncIterator()

        store.dismissAll()

        let callbacks = callbackEvents.withLock { $0 }
        var streamed: [ModalEvent<StreamRoute>] = []
        for _ in callbacks.indices {
            guard let event = await iterator.next() else {
                Issue.record("ModalStore.events ended during reentrant fan-out")
                return
            }
            streamed.append(event)
        }

        #expect(store.currentPresentation?.route == .settings)
        #expect(store.queuedPresentations.isEmpty)
        #expect(callbacks.count == 5)
        #expect(callbacks == streamed)
        guard callbacks.count == 5 else { return }
        #expect({ if case .queueChanged = callbacks[0] { true } else { false } }())
        #expect({ if case .dismissed = callbacks[1] { true } else { false } }())
        #expect({ if case .presented = callbacks[2] { true } else { false } }())
        guard case .commandIntercepted(let presentCommand, _) = callbacks[3],
              case .commandIntercepted(let dismissCommand, _) = callbacks[4]
        else {
            Issue.record("Expected reentrant present and outer dismissAll command events")
            return
        }
        #expect({ if case .present = presentCommand { true } else { false } }())
        #expect({ if case .dismissAll = dismissCommand { true } else { false } }())
    }

    // MARK: - FlowStore

    @Test("FlowStore.events wraps inner navigation events and emits .pathChanged last")
    @MainActor
    func flowEventsWrapsNavigation() async {
        let store = FlowStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        store.send(.push(.home))

        let first = await iterator.next()
        guard case .navigation(.changed(let from, let to)) = first else {
            Issue.record("Expected .navigation(.changed) first, got \(String(describing: first))")
            return
        }
        #expect(from.path.isEmpty)
        #expect(to.path == [.home])

        let second = await iterator.next()
        guard case .pathChanged(let old, let new) = second else {
            Issue.record("Expected .pathChanged second, got \(String(describing: second))")
            return
        }
        #expect(old.isEmpty)
        #expect(new == [.push(.home)])
    }

    @Test("FlowStore.events wraps modal events before .pathChanged")
    @MainActor
    func flowEventsWrapsModalBeforePathChanged() async {
        let store = FlowStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        store.send(.presentSheet(.sheet))

        let first = await iterator.next()
        guard case .modal(.presented(let presentation)) = first else {
            Issue.record("Expected .modal(.presented) first, got \(String(describing: first))")
            return
        }
        #expect(presentation.route == .sheet)

        let second = await iterator.next()
        guard case .modal(.commandIntercepted(_, let result)) = second else {
            Issue.record("Expected .modal(.commandIntercepted) second, got \(String(describing: second))")
            return
        }
        guard case .executed(.present(let presentation)) = result else {
            Issue.record("Expected .executed(.present), got \(result)")
            return
        }
        #expect(presentation.route == .sheet)

        let third = await iterator.next()
        guard case .pathChanged(let old, let new) = third else {
            Issue.record("Expected .pathChanged third, got \(String(describing: third))")
            return
        }
        #expect(old.isEmpty)
        #expect(new == [.sheet(.sheet)])
    }

    @Test("FlowStore.events wraps modal replacement before .pathChanged")
    @MainActor
    func flowEventsWrapsModalReplacementBeforePathChanged() async {
        let store = FlowStore<StreamRoute>()
        store.send(.presentSheet(.sheet))

        var iterator = store.events.makeAsyncIterator()

        store.modalStore.replaceCurrent(.settings, style: .sheet)

        let first = await iterator.next()
        guard case .modal(.replaced(let old, let new)) = first else {
            Issue.record("Expected .modal(.replaced) first, got \(String(describing: first))")
            return
        }
        #expect(old.route == .sheet)
        #expect(new.route == .settings)

        let second = await iterator.next()
        guard case .modal(.commandIntercepted(_, let result)) = second else {
            Issue.record("Expected .modal(.commandIntercepted) second, got \(String(describing: second))")
            return
        }
        guard case .executed(.replaceCurrent(let presentation)) = result else {
            Issue.record("Expected .executed(.replaceCurrent), got \(result)")
            return
        }
        #expect(presentation.route == .settings)

        let third = await iterator.next()
        guard case .pathChanged(let oldPath, let newPath) = third else {
            Issue.record("Expected .pathChanged third, got \(String(describing: third))")
            return
        }
        #expect(oldPath == [.sheet(.sheet)])
        #expect(newPath == [.sheet(.settings)])
    }

    @Test("FlowStore.events preserves order for direct inner navigation mutations")
    @MainActor
    func flowEventsPreservesDirectInnerNavigationOrder() async {
        let store = FlowStore<StreamRoute>()
        var iterator = store.events.makeAsyncIterator()

        store.navigationStore.send(.go(.home))

        let first = await iterator.next()
        guard case .navigation(.changed) = first else {
            Issue.record("Expected .navigation(.changed) first, got \(String(describing: first))")
            return
        }

        let second = await iterator.next()
        guard case .pathChanged(let old, let new) = second else {
            Issue.record("Expected .pathChanged second, got \(String(describing: second))")
            return
        }
        #expect(old.isEmpty)
        #expect(new == [.push(.home)])
        #expect(store.path == [.push(.home)])
    }

    @Test("FlowStore.events surfaces .intentRejected for push-after-modal")
    @MainActor
    func flowEventsSurfacesIntentRejected() async {
        let store = FlowStore<StreamRoute>()
        store.send(.presentSheet(.sheet))

        var iterator = store.events.makeAsyncIterator()

        store.send(.push(.detail))

        var sawRejected = false
        for _ in 0..<4 {
            let event = await iterator.next()
            if case .intentRejected(_, let reason) = event, reason == .pushBlockedByModalTail {
                sawRejected = true
                break
            }
        }
        #expect(sawRejected)
    }

    @Test("FlowStore onEvent receives wrapped inner events before pathChanged in stream order")
    @MainActor
    func flowOnEventMatchesWrappedStreamOrder() async {
        let observed = Mutex<[FlowEvent<StreamRoute>]>([])
        let store = FlowStore<StreamRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    observed.withLock { $0.append(event) }
                }
            )
        )
        var iterator = store.events.makeAsyncIterator()

        store.send(.push(.home))
        store.send(.presentSheet(.sheet))
        store.send(.push(.detail))

        let callbackEvents = observed.withLock { $0 }
        var streamEvents: [FlowEvent<StreamRoute>] = []
        for _ in callbackEvents.indices {
            guard let event = await iterator.next() else {
                Issue.record("FlowStore.events ended before matching onEvent")
                return
            }
            streamEvents.append(event)
        }

        #expect(callbackEvents == streamEvents)
        #expect(callbackEvents.count == 6)
        guard case .navigation(.changed) = callbackEvents[0] else {
            Issue.record("Expected wrapped navigation change first")
            return
        }
        guard case .pathChanged = callbackEvents[1] else {
            Issue.record("Expected navigation pathChanged second")
            return
        }
        guard case .modal(.presented) = callbackEvents[2] else {
            Issue.record("Expected wrapped modal presentation third")
            return
        }
        guard case .modal(.commandIntercepted) = callbackEvents[3] else {
            Issue.record("Expected wrapped modal interception fourth")
            return
        }
        guard case .pathChanged = callbackEvents[4] else {
            Issue.record("Expected modal pathChanged after wrapped inner events")
            return
        }
        guard case .intentRejected(.push(.detail), .pushBlockedByModalTail) = callbackEvents[5] else {
            Issue.record("Expected flow rejection last")
            return
        }
    }
}
