// MARK: - ModalTestStore.swift
// InnoRouterTesting - host-less modal test harness
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore
import InnoRouterSwiftUI

/// A host-less, Swift-Testing native assertion harness for `ModalStore`.
///
/// `ModalTestStore` wraps a private `ModalStore<M>` and subscribes to its
/// unified public observation callback.
/// Emitted events are buffered into a FIFO queue and consumed by
/// `receive(...)` calls in test-authored order.
///
/// The event order reflects the production store's real emission order.
/// Executed commands may emit presentation / dismissal / replacement / queue
/// events while applying the command, before the final command-interception
/// event. Cancelled commands emit only the command-interception event.
///
/// See `TestExhaustivity` for strictness modes.
@MainActor
public final class ModalTestStore<M: Route> {

    // MARK: - Stored

    private let underlying: ModalStore<M>
    private let queue: TestEventQueue<ModalEvent<M>>

    // MARK: - Init

    /// Creates a test store wrapping an internally owned `ModalStore`.
    public init(
        currentPresentation: ModalPresentation<M>? = nil,
        queuedPresentations: [ModalPresentation<M>] = [],
        configuration: ModalStoreConfiguration<M> = .init(),
        exhaustivity: TestExhaustivity = .strict
    ) {
        let queue = TestEventQueue<ModalEvent<M>>(
            storeName: "ModalTestStore",
            exhaustivity: exhaustivity
        )
        self.queue = queue
        self.underlying = ModalStore(
            currentPresentation: currentPresentation,
            queuedPresentations: queuedPresentations,
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

    // MARK: - Accessors

    /// The wrapped `ModalStore`.
    public var store: ModalStore<M> {
        underlying
    }

    /// The currently active presentation, if any.
    public var currentPresentation: ModalPresentation<M>? {
        underlying.currentPresentation
    }

    /// The currently queued presentations (FIFO), not including `currentPresentation`.
    public var queuedPresentations: [ModalPresentation<M>] {
        underlying.queuedPresentations
    }

    /// Snapshot of unconsumed events.
    public var unassertedEvents: [ModalEvent<M>] {
        queue.remaining
    }

    // MARK: - Execution

    /// Forwards a `ModalIntent` through the production dispatcher.
    public func send(_ intent: ModalIntent<M>) {
        underlying.send(intent)
    }

    /// Forwards a raw `ModalCommand` through `ModalStore.execute(_:)`.
    @discardableResult
    public func execute(_ command: ModalCommand<M>) -> ModalExecutionResult<M> {
        underlying.execute(command)
    }

    /// Forwards to `ModalStore.present(_:style:)`.
    @discardableResult
    public func present(
        _ route: M,
        style: ModalPresentationStyle = .sheet
    ) -> ModalPresentResult<M> {
        underlying.present(route, style: style)
    }

    /// Forwards to `ModalStore.dismissCurrent()`.
    @discardableResult
    public func dismissCurrent() -> ModalExecutionResult<M> {
        underlying.dismissCurrent()
    }

    /// Forwards to `ModalStore.dismissAll()`.
    @discardableResult
    public func dismissAll() -> ModalExecutionResult<M> {
        underlying.dismissAll()
    }

    // MARK: - Assertion

    /// Dequeues the next event and asserts equality with `expected`.
    public func receive(
        _ expected: ModalEvent<M>,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "ModalTestStore.receive(\(expected)) — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if actual != expected {
            recordTestStoreIssue(
                """
                ModalTestStore.receive mismatch.
                Expected: \(expected)
                Actual:   \(actual)
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.presented(...)` for
    /// the given route.
    public func receivePresented(
        _ route: M,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "ModalTestStore.receivePresented(\(route)) — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .presented(let presentation) = actual else {
            recordTestStoreIssue(
                "ModalTestStore.receivePresented — expected .presented, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if presentation.route != route {
            recordTestStoreIssue(
                "ModalTestStore.receivePresented — expected route \(route), got \(presentation.route).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.dismissed(...)`
    /// matching `predicate`.
    public func receiveDismissed(
        _ predicate: (ModalPresentation<M>, ModalDismissalReason) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "ModalTestStore.receiveDismissed — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .dismissed(let presentation, let reason) = actual else {
            recordTestStoreIssue(
                "ModalTestStore.receiveDismissed — expected .dismissed, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(presentation, reason) {
            recordTestStoreIssue(
                "ModalTestStore.receiveDismissed predicate failed for (\(presentation.route), \(reason)).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.queueChanged(...)`
    /// matching `predicate`.
    public func receiveQueueChanged(
        _ predicate: ([ModalPresentation<M>], [ModalPresentation<M>]) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "ModalTestStore.receiveQueueChanged — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .queueChanged(let old, let new) = actual else {
            recordTestStoreIssue(
                "ModalTestStore.receiveQueueChanged — expected .queueChanged, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(old, new) {
            recordTestStoreIssue(
                "ModalTestStore.receiveQueueChanged predicate failed.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.commandIntercepted(...)`
    /// matching `predicate`.
    public func receiveIntercepted(
        _ predicate: (ModalCommand<M>, ModalExecutionResult<M>) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "ModalTestStore.receiveIntercepted — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .commandIntercepted(let command, let result) = actual else {
            recordTestStoreIssue(
                "ModalTestStore.receiveIntercepted — expected .commandIntercepted, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(command, result) {
            recordTestStoreIssue(
                "ModalTestStore.receiveIntercepted predicate failed.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.middlewareMutation(...)`
    /// with the given action.
    public func receiveMiddlewareMutation(
        action: ModalMiddlewareMutationEvent<M>.Action,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "ModalTestStore.receiveMiddlewareMutation — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .middlewareMutation(let event) = actual else {
            recordTestStoreIssue(
                "ModalTestStore.receiveMiddlewareMutation — expected .middlewareMutation, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if event.action != action {
            recordTestStoreIssue(
                "ModalTestStore.receiveMiddlewareMutation — expected action \(action.rawValue), got \(event.action.rawValue).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    // MARK: - Completion

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

    // MARK: - Internals

    private static func wrapConfiguration(
        _ original: ModalStoreConfiguration<M>,
        queue: TestEventQueue<ModalEvent<M>>
    ) -> ModalStoreConfiguration<M> {
        var wrapped = original
        wrapped.onEvent = { @MainActor [queue] event in
            original.onEvent?(event)
            queue.enqueue(event)
        }
        return wrapped
    }
}
