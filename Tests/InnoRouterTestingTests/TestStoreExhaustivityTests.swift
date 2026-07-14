// MARK: - TestStoreExhaustivityTests.swift
// InnoRouterTestingTests - TestExhaustivity .strict vs .off
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterTesting

private enum ExhaustivityRoute: Route {
    case a
    case b
}

@Suite("TestStore Exhaustivity Tests")
struct TestStoreExhaustivityTests {

    @Test(".strict finish reports pending events for every test store")
    @MainActor
    func strictFinishReportsPendingEvents() {
        withKnownIssue {
            let store = NavigationTestStore<ExhaustivityRoute>()
            store.send(.go(.a))
            store.finish()
        }
        withKnownIssue {
            let store = ModalTestStore<ExhaustivityRoute>()
            store.present(.a)
            store.finish()
        }
        withKnownIssue {
            let store = FlowTestStore<ExhaustivityRoute>()
            store.send(.push(.a))
            store.finish()
        }
    }

    @Test(".off finish silently drains pending events for every test store")
    @MainActor
    func offFinishDrainsWithoutFailure() {
        let navigation = NavigationTestStore<ExhaustivityRoute>(exhaustivity: .off)
        navigation.send(.go(.a))
        navigation.finish()
        #expect(navigation.unassertedEvents.isEmpty)

        let modal = ModalTestStore<ExhaustivityRoute>(exhaustivity: .off)
        modal.present(.a)
        modal.finish()
        #expect(modal.unassertedEvents.isEmpty)

        let flow = FlowTestStore<ExhaustivityRoute>(exhaustivity: .off)
        flow.send(.push(.a))
        flow.finish()
        #expect(flow.unassertedEvents.isEmpty)
    }

    @Test("assertNoPendingEvents is a non-terminal checkpoint")
    @MainActor
    func checkpointKeepsObservationActive() {
        let navigation = NavigationTestStore<ExhaustivityRoute>()
        navigation.assertNoPendingEvents()
        navigation.send(.go(.a))
        navigation.receiveChange()
        navigation.finish()

        let modal = ModalTestStore<ExhaustivityRoute>()
        modal.assertNoPendingEvents()
        modal.present(.a)
        modal.receivePresented(.a)
        modal.receiveIntercepted()
        modal.finish()

        let flow = FlowTestStore<ExhaustivityRoute>()
        flow.assertNoPendingEvents()
        flow.send(.push(.a))
        flow.receiveNavigation()
        flow.receivePathChanged()
        flow.finish()
    }

    @Test("a failing checkpoint consumes its snapshot and remains active")
    @MainActor
    func failingCheckpointConsumesSnapshot() {
        let store = NavigationTestStore<ExhaustivityRoute>()
        store.send(.go(.a))

        withKnownIssue {
            store.assertNoPendingEvents()
        }
        #expect(store.unassertedEvents.isEmpty)

        store.send(.go(.b))
        store.receiveChange()
        store.finish()
    }

    @Test("skipReceivedEvents drains the queue without finishing")
    @MainActor
    func skipReceivedEventsDrains() {
        let store = NavigationTestStore<ExhaustivityRoute>()
        store.send(.go(.a))
        store.skipReceivedEvents()
        #expect(store.unassertedEvents.isEmpty)

        store.send(.go(.b))
        store.receiveChange()
        store.finish()
    }

    @Test("finish() is idempotent — subsequent calls do not re-fire")
    @MainActor
    func finishIsIdempotent() {
        let store = NavigationTestStore<ExhaustivityRoute>()
        store.send(.go(.a))
        store.receiveChange()
        store.finish()
        store.finish() // second call is a no-op
    }

    @Test("finish reports the first late event for every test store")
    @MainActor
    func finishReportsLateEvents() {
        let navigation = NavigationTestStore<ExhaustivityRoute>()
        withKnownIssue {
            navigation.finish(line: 12_345)
            navigation.send(.go(.a))
        } matching: { issue in
            issue.sourceLocation?.line == 12_345
                && issue.comments.contains {
                    $0.rawValue.contains("NavigationTestStore received an event after finish()")
                }
        }
        navigation.send(.go(.b))
        #expect(navigation.unassertedEvents.isEmpty)

        let modal = ModalTestStore<ExhaustivityRoute>()
        withKnownIssue {
            modal.finish()
            modal.present(.a)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("- .presented") }
        }
        modal.dismissCurrent()
        #expect(modal.unassertedEvents.isEmpty)

        let flow = FlowTestStore<ExhaustivityRoute>()
        withKnownIssue {
            flow.finish()
            flow.send(.push(.a))
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("- .navigation") }
        }
        flow.send(.push(.b))
        #expect(flow.unassertedEvents.isEmpty)
    }

    @Test(".off does not suppress events emitted after finish")
    @MainActor
    func offStillReportsLateEvents() {
        let navigation = NavigationTestStore<ExhaustivityRoute>(exhaustivity: .off)
        withKnownIssue {
            navigation.finish()
            navigation.send(.go(.a))
        }

        let modal = ModalTestStore<ExhaustivityRoute>(exhaustivity: .off)
        withKnownIssue {
            modal.finish()
            modal.present(.a)
        }

        let flow = FlowTestStore<ExhaustivityRoute>(exhaustivity: .off)
        withKnownIssue {
            flow.finish()
            flow.send(.push(.a))
        }
    }

    @Test("retained underlying store still reports events after explicit finish")
    @MainActor
    func retainedUnderlyingStoreReportsLateEvent() {
        withKnownIssue {
            let underlying: NavigationStore<ExhaustivityRoute>
            do {
                let testStore = NavigationTestStore<ExhaustivityRoute>()
                underlying = testStore.store
                testStore.finish()
            }
            underlying.send(.go(.a))
        }
    }
}
