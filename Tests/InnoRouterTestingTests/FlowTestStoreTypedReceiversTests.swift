// MARK: - FlowTestStoreTypedReceiversTests.swift
// InnoRouterTestingTests - typed sub-event receiver overloads
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import InnoRouter
import InnoRouterCore
import InnoRouterSwiftUI
import InnoRouterTesting

private enum TypedRoute: Route {
    case landing
    case details
    case sheet
}

@Suite("FlowTestStore typed sub-event receivers")
struct FlowTestStoreTypedReceiversTests {

    // MARK: - Navigation success paths

    @Test("receiveNavigationChanged matches a .changed payload")
    @MainActor
    func receiveNavigationChangedMatches() {
        let store = FlowTestStore<TypedRoute>()

        store.send(.push(.landing))

        store.receiveNavigationChanged { from, to in
            from.path.isEmpty && to.path == [.landing]
        }
        // The .pathChanged event still trails — drain it via predicate-free
        // helper to keep the harness exhaustive.
        store.receivePathChanged()
        store.finish()
    }

    @Test("receiveNavigationChanged without predicate accepts any payload")
    @MainActor
    func receiveNavigationChangedAcceptsAnyPayload() {
        let store = FlowTestStore<TypedRoute>()

        store.send(.push(.details))

        store.receiveNavigationChanged()
        store.receivePathChanged()
        store.finish()
    }

    // MARK: - Modal success paths

    @Test("receiveModalPresented matches a .presented payload")
    @MainActor
    func receiveModalPresentedMatches() {
        let store = FlowTestStore<TypedRoute>()

        store.send(.presentSheet(.sheet))

        store.receiveModalPresented { presentation in
            presentation.route == .sheet && presentation.style == .sheet
        }
        // Trailing .commandIntercepted + .pathChanged events.
        store.receiveModalCommandIntercepted()
        store.receivePathChanged()
        store.finish()
    }

    @Test("receiveModalCommandIntercepted matches an .executed result")
    @MainActor
    func receiveModalCommandInterceptedMatches() {
        let store = FlowTestStore<TypedRoute>()

        store.send(.presentSheet(.sheet))
        // Drain the .presented event first.
        store.receiveModalPresented()

        store.receiveModalCommandIntercepted { _, result in
            if case .executed = result { return true }
            return false
        }
        store.receivePathChanged()
        store.finish()
    }

    // MARK: - Wrong-case failure paths

    @Test("receiveModalPresented on a navigation event records a clear issue")
    @MainActor
    func receiveModalPresentedOnNavigationEventFails() {
        withKnownIssue {
            let store = FlowTestStore<TypedRoute>(exhaustivity: .off)
            store.send(.push(.landing))
            // Next event is .navigation(.changed) — wrong wrapper.
            store.receiveModalPresented()
        }
    }

    @Test("receiveNavigationBatch on a .changed event records a clear issue")
    @MainActor
    func receiveNavigationBatchOnChangedEventFails() {
        withKnownIssue {
            let store = FlowTestStore<TypedRoute>(exhaustivity: .off)
            store.send(.push(.landing))
            // Next navigation event is .changed, not .batchExecuted.
            store.receiveNavigationBatch()
        }
    }

    @Test("receiveModalDismissed on a .presented event records a clear issue")
    @MainActor
    func receiveModalDismissedOnPresentedEventFails() {
        withKnownIssue {
            let store = FlowTestStore<TypedRoute>(exhaustivity: .off)
            store.send(.presentSheet(.sheet))
            // Next modal event is .presented, not .dismissed.
            store.receiveModalDismissed()
        }
    }

    // MARK: - Predicate failure path

    @Test("receiveNavigationChanged with failing predicate records an issue")
    @MainActor
    func receiveNavigationChangedFailingPredicateFails() {
        withKnownIssue {
            let store = FlowTestStore<TypedRoute>(exhaustivity: .off)
            store.send(.push(.landing))
            store.receiveNavigationChanged { _, to in
                to.path == [.details] // wrong target on purpose
            }
        }
    }

    // MARK: - Empty queue path

    @Test("receiveNavigationChanged on empty queue records an issue")
    @MainActor
    func receiveNavigationChangedOnEmptyQueueFails() {
        withKnownIssue {
            let store = FlowTestStore<TypedRoute>(exhaustivity: .off)
            store.receiveNavigationChanged()
        }
    }
}
