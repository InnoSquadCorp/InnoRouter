// MARK: - FlowIntentNamedIntentsTests.swift
// InnoRouterTests - FlowIntent.replaceStack / .backOrPush / .pushUniqueRoot
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
@testable import InnoRouterSwiftUI

private enum NamedRoute: Route {
    case home
    case detail
    case settings
    case sheet
}

@Suite("FlowIntent Named Intent Tests")
struct FlowIntentNamedIntentsTests {

    // MARK: - replaceStack

    @Test(".replaceStack from clean path swaps the push prefix")
    @MainActor
    func replaceStackFromCleanPath() {
        let store = FlowStore<NamedRoute>()

        store.send(.replaceStack([.home, .detail]))

        #expect(store.path == [.push(.home), .push(.detail)])
        #expect(store.navigationStore.state.path == [.home, .detail])
        #expect(store.modalStore.currentPresentation == nil)
    }

    @Test(".replaceStack drops an active modal tail")
    @MainActor
    func replaceStackDropsModalTail() {
        let store = FlowStore<NamedRoute>()
        store.send(.push(.home))
        store.send(.presentSheet(.sheet))
        #expect(store.modalStore.currentPresentation?.route == .sheet)

        store.send(.replaceStack([.settings]))

        #expect(store.path == [.push(.settings)])
        #expect(store.navigationStore.state.path == [.settings])
        #expect(store.modalStore.currentPresentation == nil)
    }

    @Test(".replaceStack emits a single pathChanged event")
    @MainActor
    func replaceStackEmitsPathChanged() {
        let captured = Mutex<[[RouteStep<NamedRoute>]]>([])
        let store = FlowStore<NamedRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .pathChanged(_, let new) = event else { return }
                    captured.withLock { $0.append(new) }
                }
            )
        )

        store.send(.replaceStack([.home, .detail]))

        let paths = captured.withLock { $0 }
        #expect(paths == [[.push(.home), .push(.detail)]])
    }

    // MARK: - backOrPush

    @Test(".backOrPush pops to existing route without a rejection event")
    @MainActor
    func backOrPushPopsExisting() {
        let rejections = Mutex<[(FlowIntent<NamedRoute>, FlowRejectionReason)]>([])
        let store = FlowStore<NamedRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )
        store.send(.push(.home))
        store.send(.push(.detail))
        store.send(.push(.settings))

        store.send(.backOrPush(.detail))

        #expect(store.navigationStore.state.path == [.home, .detail])
        #expect(store.path == [.push(.home), .push(.detail)])
        #expect(rejections.withLock { $0.isEmpty })
    }

    @Test(".backOrPush pushes when route is absent")
    @MainActor
    func backOrPushPushesWhenAbsent() {
        let store = FlowStore<NamedRoute>()
        store.send(.push(.home))

        store.send(.backOrPush(.detail))

        #expect(store.path == [.push(.home), .push(.detail)])
    }

    @Test(".backOrPush rejects with .pushBlockedByModalTail when modal is active and route is new")
    @MainActor
    func backOrPushRejectsUnderModal() throws {
        let rejections = Mutex<[(FlowIntent<NamedRoute>, FlowRejectionReason)]>([])
        let store = FlowStore<NamedRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )
        store.send(.push(.home))
        store.send(.presentSheet(.sheet))

        store.send(.backOrPush(.detail))

        let captured = rejections.withLock { $0 }
        let first = try #require(captured.first)
        #expect(captured.count == 1)
        if case (.backOrPush(.detail), .pushBlockedByModalTail) = (first.0, first.1) {
            // expected
        } else {
            Issue.record("Expected backOrPush rejection with pushBlockedByModalTail, got \(captured)")
        }
        #expect(store.modalStore.currentPresentation?.route == .sheet)
    }

    @Test(".backOrPush rejects with .pushBlockedByModalTail when modal is active and route already exists")
    @MainActor
    func backOrPushExistingRouteRejectsUnderModal() throws {
        let rejections = Mutex<[(FlowIntent<NamedRoute>, FlowRejectionReason)]>([])
        let store = FlowStore<NamedRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )
        store.send(.push(.home))
        store.send(.push(.detail))
        store.send(.presentSheet(.sheet))

        store.send(.backOrPush(.home))

        let captured = rejections.withLock { $0 }
        let first = try #require(captured.first)
        #expect(captured.count == 1)
        if case (.backOrPush(.home), .pushBlockedByModalTail) = (first.0, first.1) {
            // expected
        } else {
            Issue.record("Expected backOrPush rejection for existing route, got \(captured)")
        }
        #expect(store.path == [.push(.home), .push(.detail), .sheet(.sheet)])
    }

    // MARK: - pushUniqueRoot

    @Test(".pushUniqueRoot is a silent no-op when stack root already matches")
    @MainActor
    func pushUniqueRootNoOpsWhenMatching() {
        let captured = Mutex<[[RouteStep<NamedRoute>]]>([])
        let store = FlowStore<NamedRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .pathChanged(_, let new) = event else { return }
                    captured.withLock { $0.append(new) }
                }
            )
        )
        store.send(.push(.home))
        captured.withLock { $0.removeAll() }

        store.send(.pushUniqueRoot(.home))

        #expect(store.path == [.push(.home)])
        #expect(captured.withLock { $0.isEmpty })
    }

    @Test(".pushUniqueRoot pushes when current root differs")
    @MainActor
    func pushUniqueRootPushesWhenDifferent() {
        let store = FlowStore<NamedRoute>()

        store.send(.pushUniqueRoot(.home))

        #expect(store.path == [.push(.home)])
    }

    @Test(".pushUniqueRoot is a silent no-op when the route already exists deeper in the stack")
    @MainActor
    func pushUniqueRootNoOpsWhenAlreadyPresent() {
        let captured = Mutex<[[RouteStep<NamedRoute>]]>([])
        let store = FlowStore<NamedRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .pathChanged(_, let new) = event else { return }
                    captured.withLock { $0.append(new) }
                }
            )
        )
        store.send(.push(.home))
        store.send(.push(.detail))
        store.send(.push(.settings))
        captured.withLock { $0.removeAll() }

        store.send(.pushUniqueRoot(.detail))

        #expect(store.path == [.push(.home), .push(.detail), .push(.settings)])
        #expect(captured.withLock { $0.isEmpty })
    }

    @Test(".pushUniqueRoot rejects under an active modal tail")
    @MainActor
    func pushUniqueRootRejectsUnderModal() throws {
        let rejections = Mutex<[(FlowIntent<NamedRoute>, FlowRejectionReason)]>([])
        let store = FlowStore<NamedRoute>(
            configuration: FlowStoreConfiguration(
                onEvent: { event in
                    guard case .intentRejected(let intent, let reason) = event else { return }
                    rejections.withLock { $0.append((intent, reason)) }
                }
            )
        )
        store.send(.push(.home))
        store.send(.presentSheet(.sheet))

        store.send(.pushUniqueRoot(.detail))

        let captured = rejections.withLock { $0 }
        let first = try #require(captured.first)
        #expect(captured.count == 1)
        if case (.pushUniqueRoot(.detail), .pushBlockedByModalTail) = (first.0, first.1) {
            // expected
        } else {
            Issue.record("Expected pushUniqueRoot rejection, got \(captured)")
        }
    }

    // MARK: - End-to-end through events stream

    @Test(".replaceStack shows on FlowStore.events as .pathChanged")
    @MainActor
    func replaceStackSurfacesOnEventsStream() async {
        let store = FlowStore<NamedRoute>()
        var iterator = store.events.makeAsyncIterator()

        store.send(.replaceStack([.home, .detail]))

        var sawPathChanged = false
        for _ in 0..<6 {
            let event = await iterator.next()
            if case .pathChanged(let old, let new) = event,
               old.isEmpty,
               new == [.push(.home), .push(.detail)] {
                sawPathChanged = true
                break
            }
        }
        #expect(sawPathChanged)
    }
}
