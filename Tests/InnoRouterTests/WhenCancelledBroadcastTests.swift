// MARK: - WhenCancelledBroadcastTests.swift
// InnoRouterTests - .whenCancelled broadcaster ordering / leakage contract
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import InnoRouterCore
@testable import InnoRouterSwiftUI

// MARK: - Local fixtures

private enum WCBRoute: String, Route {
    case home, detail, settings
}

@MainActor
private func blockingMiddleware(
    predicate: @escaping @MainActor @Sendable (NavigationCommand<WCBRoute>) -> Bool
) -> AnyNavigationMiddleware<WCBRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in
        predicate(command) ? .cancel(.middleware(debugName: "blocking", command: command)) : .proceed(command)
    })
}

/// Collector wired to `NavigationStoreConfiguration.onEvent`. The
/// store invokes `onEvent` synchronously inside `execute()` from the
/// same call site that broadcasts the matching `.changed` event, so an
/// onEvent-based count is a faithful proxy for the broadcaster's
/// `.changed` count for the contract under test, while sidestepping
/// the "wait for events that may never arrive" hazard of an
/// `AsyncStream` iterator.
@MainActor
private final class ChangeCollector {
    var changes: [(from: [WCBRoute], to: [WCBRoute])] = []
}

@MainActor
private func makeStore(
    initialPath: [WCBRoute] = [],
    middlewares: [NavigationMiddlewareRegistration<WCBRoute>] = []
) throws -> (NavigationStore<WCBRoute>, ChangeCollector) {
    let collector = ChangeCollector()
    let store = try NavigationStore<WCBRoute>(
        initialPath: initialPath,
        configuration: NavigationStoreConfiguration<WCBRoute>(
            middlewares: middlewares,
            onEvent: { event in
                guard case .changed(let old, let new) = event else { return }
                MainActor.assumeIsolated {
                    collector.changes.append((old.path, new.path))
                }
            }
        )
    )
    return (store, collector)
}

// MARK: - Suite

@Suite(".whenCancelled broadcaster contract")
struct WhenCancelledBroadcastTests {

    // The contract: a `.whenCancelled(primary, fallback)` always emits
    // at most one `.changed` for the *net* transition seen by the
    // store. Intermediate states from either attempted leg never leak.
    // A successful leg emits one `oldRoot → finalRoot` transition; if
    // both legs fail, no change is emitted.

    @Test("Primary success: one .changed from initial to primary's final state")
    @MainActor
    func primarySuccessEmitsSingleChange() throws {
        let (store, collector) = try makeStore()
        _ = store.execute(
            .whenCancelled(.push(.home), fallback: .push(.detail))
        )
        #expect(collector.changes.count == 1)
        #expect(collector.changes.first?.from == [])
        #expect(collector.changes.first?.to == [.home])
        #expect(store.state.path == [.home])
    }

    @Test("Primary engine-fail with partial sequence: rollback + fallback emit one .changed")
    @MainActor
    func partialPrimarySequenceRollsBackBeforeFallback() throws {
        let (store, collector) = try makeStore()
        // sequence(push(home), popTo(settings)) — popTo fails on a
        // stack that contains only `home`. The push(.home) inside the
        // sequence applies temporarily but the failure rolls the
        // stack back to empty before fallback runs.
        _ = store.execute(
            .whenCancelled(
                .sequence([.push(.home), .popTo(.settings)]),
                fallback: .push(.detail)
            )
        )
        // The contract: do NOT leak a `[] → [.home]` transition for
        // the partial sequence, only the net `[] → [.detail]` from
        // the fallback commit.
        #expect(collector.changes.count == 1)
        #expect(collector.changes.first?.from == [])
        #expect(collector.changes.first?.to == [.detail])
        #expect(store.state.path == [.detail])
    }

    @Test("Failed fallback sequence emits no transient .changed event")
    @MainActor
    func partialFallbackFailureEmitsNothing() throws {
        let (store, collector) = try makeStore()

        let result = store.execute(
            .whenCancelled(
                .pop,
                fallback: .sequence([.push(.home), .popTo(.settings)])
            )
        )

        #expect(result == .multiple([.success, .routeNotFound(.settings)]))
        #expect(collector.changes.isEmpty)
        #expect(store.state.path.isEmpty)
    }

    @Test("Middleware-cancelled primary: fallback's net change emits exactly once")
    @MainActor
    func middlewareCancelledPrimaryEmitsFallbackOnly() throws {
        let (store, collector) = try makeStore(
            middlewares: [
                .init(middleware: blockingMiddleware { command in
                    if case .push(.detail) = command { return true }
                    return false
                })
            ]
        )
        _ = store.execute(
            .whenCancelled(.push(.detail), fallback: .push(.home))
        )
        #expect(collector.changes.count == 1)
        #expect(collector.changes.first?.to == [.home])
    }

    @Test("Primary success that produces same state as before emits no .changed")
    @MainActor
    func primarySuccessWithoutStateChangeEmitsNothing() throws {
        let (store, collector) = try makeStore(initialPath: [.home])
        // popTo(.home) leaves the stack as-is. No state change → no
        // .changed event.
        _ = store.execute(
            .whenCancelled(.popTo(.home), fallback: .push(.detail))
        )
        #expect(collector.changes.isEmpty)
        #expect(store.state.path == [.home])
    }
}
