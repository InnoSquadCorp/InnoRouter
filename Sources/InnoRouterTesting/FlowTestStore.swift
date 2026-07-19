// MARK: - FlowTestStore.swift
// InnoRouterTesting - host-less flow test harness
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore
import InnoRouterSwiftUI

/// A host-less, Swift-Testing native assertion harness for `FlowStore`.
///
/// `FlowTestStore` wraps a private `FlowStore<R>` and records its unified
/// event surface in FIFO order. General and typed receiver helpers live in
/// focused extensions while this type owns lifecycle and execution only.
@MainActor
public final class FlowTestStore<R: Route> {
    private let underlying: FlowStore<R>
    let queue: TestEventQueue<FlowEvent<R>>

    public init(
        initial: [RouteStep<R>] = [],
        configuration: FlowStoreConfiguration<R> = .init(),
        exhaustivity: TestExhaustivity = .strict
    ) {
        let queue = TestEventQueue<FlowEvent<R>>(
            storeName: "FlowTestStore",
            exhaustivity: exhaustivity
        )
        self.queue = queue
        self.underlying = FlowStore(
            initial: initial,
            configuration: Self.wrapConfiguration(configuration, queue: queue)
        )
    }

    isolated deinit {
        queue.finishAtDeinitialization(
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
    }

    public var store: FlowStore<R> {
        underlying
    }

    public var path: [RouteStep<R>] {
        underlying.path
    }

    public var unassertedEvents: [FlowEvent<R>] {
        queue.remaining
    }

    public func send(_ intent: FlowIntent<R>) {
        underlying.send(intent)
    }

    @discardableResult
    public func apply(_ plan: FlowPlan<R>) -> FlowPlanApplyResult<R> {
        underlying.apply(plan)
    }

    /// Asserts and consumes currently queued events without finishing the store.
    /// Later operations continue to enqueue normally.
    public func assertNoPendingEvents(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        queue.assertNoPendingEvents(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Runs the final exhaustivity check and closes the observation queue.
    /// The first later event reports an issue in either exhaustivity mode.
    public func finish(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        queue.finish(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    public func skipReceivedEvents() {
        queue.drain()
    }

    private static func wrapConfiguration(
        _ original: FlowStoreConfiguration<R>,
        queue: TestEventQueue<FlowEvent<R>>
    ) -> FlowStoreConfiguration<R> {
        var wrapped = original
        wrapped.onEvent = { @MainActor [queue] event in
            original.onEvent?(event)
            queue.enqueue(event)
        }
        return wrapped
    }
}
