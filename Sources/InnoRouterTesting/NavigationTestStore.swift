// MARK: - NavigationTestStore.swift
// InnoRouterTesting - host-less navigation test harness
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore
import InnoRouterSwiftUI

/// A host-less, Swift-Testing native assertion harness for `NavigationStore`.
///
/// `NavigationTestStore` wraps a private `NavigationStore<R>` and mirrors
/// its public execution surface (`send`, `execute`, `executeBatch`,
/// `executeTransaction`). Middleware registry APIs remain available through
/// the wrapped `store` escape hatch. It transparently subscribes to the
/// unified public `onEvent` callback, buffers the emitted events, and exposes
/// a TCA `TestStore`-style
/// `receive(...)` API for consuming them in order.
///
/// ```swift
/// let store = NavigationTestStore<AppRoute>()
/// store.send(.push(.home))
/// store.receive(.changed(from: .init(), to: try! .init(validating: [.home])))
/// ```
///
/// User-supplied callbacks on `NavigationStoreConfiguration` are preserved:
/// they fire first, then the test store enqueues the event. This lets
/// production configurations (for example, analytics middleware) run under
/// test exactly as they would in the app.
///
/// See `TestExhaustivity` for strictness modes.
@MainActor
public final class NavigationTestStore<R: Route> {

    // MARK: - Stored

    private let underlying: NavigationStore<R>
    private let queue: TestEventQueue<NavigationEvent<R>>

    // MARK: - Init

    /// Creates a test store wrapping an internally owned `NavigationStore`.
    ///
    /// - Parameters:
    ///   - initial: The starting stack.
    ///   - configuration: Any production configuration the test wants to
    ///     apply. All observation hooks remain active — the test store
    ///     appends to them rather than replacing them.
    ///   - exhaustivity: Strictness mode. Defaults to `.strict`, matching
    ///     TCA's `TestStore` behaviour: unasserted events at deallocation
    ///     are reported as Swift Testing issues.
    public init(
        initial: RouteStack<R> = .init(),
        configuration: NavigationStoreConfiguration<R> = .init(),
        exhaustivity: TestExhaustivity = .strict
    ) {
        let queue = TestEventQueue<NavigationEvent<R>>(
            storeName: "NavigationTestStore",
            exhaustivity: exhaustivity
        )
        self.queue = queue
        self.underlying = NavigationStore(
            initial: initial,
            configuration: Self.wrapConfiguration(configuration, queue: queue)
        )
    }

    /// Creates a test store from an initial `[R]` path, validating through
    /// the same `RouteStackValidator` as the production store.
    public convenience init(
        initialPath: [R],
        configuration: NavigationStoreConfiguration<R> = .init(),
        exhaustivity: TestExhaustivity = .strict
    ) throws {
        let initial = try RouteStack(
            validating: initialPath,
            using: configuration.routeStackValidator
        )
        self.init(
            initial: initial,
            configuration: configuration,
            exhaustivity: exhaustivity
        )
    }

    isolated deinit {
        // @MainActor-isolated deinit (SE-0371 / Swift 6.2). Safe to touch
        // MainActor state because the runtime schedules the deinit body
        // onto the MainActor executor.
        queue.finishAtDeinitialization(
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
    }

    // MARK: - Accessors

    /// The current stack on the wrapped `NavigationStore`.
    public var state: RouteStack<R> {
        underlying.state
    }

    /// The wrapped `NavigationStore`. Exposed as an escape hatch for tests
    /// that need to drive middleware registry APIs or attach additional
    /// observers.
    public var store: NavigationStore<R> {
        underlying
    }

    /// A snapshot of events that have been observed but not yet asserted.
    public var unassertedEvents: [NavigationEvent<R>] {
        queue.remaining
    }

    // MARK: - Execution (forwarded to underlying store)

    /// Forwards a `NavigationIntent` through the production dispatcher.
    public func send(_ intent: NavigationIntent<R>) {
        underlying.send(intent)
    }

    /// Forwards a single command through the production executor.
    @discardableResult
    public func execute(_ command: NavigationCommand<R>) -> NavigationResult<R> {
        underlying.execute(command)
    }

    /// Forwards a batch through the production executor.
    @discardableResult
    public func executeBatch(
        _ commands: [NavigationCommand<R>],
        stopOnFailure: Bool = false
    ) -> NavigationBatchResult<R> {
        underlying.executeBatch(commands, stopOnFailure: stopOnFailure)
    }

    /// Forwards a transaction through the production executor.
    @discardableResult
    public func executeTransaction(
        _ commands: [NavigationCommand<R>]
    ) -> NavigationTransactionResult<R> {
        underlying.executeTransaction(commands)
    }

    // MARK: - Assertion

    /// Dequeues the next event and asserts it equals `expected`. Fails via
    /// Swift Testing `Issue.record` if the queue is empty or the event
    /// differs.
    public func receive(
        _ expected: NavigationEvent<R>,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "NavigationTestStore.receive(\(expected)) — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if actual != expected {
            recordTestStoreIssue(
                """
                NavigationTestStore.receive mismatch.
                Expected: \(expected)
                Actual:   \(actual)
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and runs `predicate` on it. Fails if the
    /// queue is empty or the predicate returns `false`.
    @discardableResult
    public func receive(
        _ predicate: (NavigationEvent<R>) -> Bool,
        failureMessage: @autoclosure () -> String = "predicate returned false",
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) -> NavigationEvent<R>? {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "NavigationTestStore.receive(predicate) — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return nil
        }
        if !predicate(actual) {
            recordTestStoreIssue(
                "NavigationTestStore.receive(predicate) failed for \(actual): \(failureMessage())",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
        return actual
    }

    /// Dequeues the next event and asserts it is a `.changed(...)` matching
    /// `predicate`. Fails otherwise.
    public func receiveChange(
        _ predicate: (RouteStack<R>, RouteStack<R>) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveChange — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .changed(let from, let to) = actual else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveChange — expected .changed, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(from, to) {
            recordTestStoreIssue(
                "NavigationTestStore.receiveChange predicate failed for (\(from.path), \(to.path)).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.batchExecuted(...)`
    /// matching `predicate`. Fails otherwise.
    public func receiveBatch(
        _ predicate: (NavigationBatchResult<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveBatch — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .batchExecuted(let result) = actual else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveBatch — expected .batchExecuted, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(result) {
            recordTestStoreIssue(
                "NavigationTestStore.receiveBatch predicate failed.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.transactionExecuted(...)`
    /// matching `predicate`. Fails otherwise.
    public func receiveTransaction(
        _ predicate: (NavigationTransactionResult<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveTransaction — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .transactionExecuted(let result) = actual else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveTransaction — expected .transactionExecuted, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(result) {
            recordTestStoreIssue(
                "NavigationTestStore.receiveTransaction predicate failed.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.middlewareMutation(...)`
    /// matching `action`. Fails otherwise.
    public func receiveMiddlewareMutation(
        action: MiddlewareMutationEvent<R>.Action,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveMiddlewareMutation — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .middlewareMutation(let event) = actual else {
            recordTestStoreIssue(
                "NavigationTestStore.receiveMiddlewareMutation — expected .middlewareMutation, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if event.action != action {
            recordTestStoreIssue(
                "NavigationTestStore.receiveMiddlewareMutation — expected action \(action.rawValue), got \(event.action.rawValue).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    /// Dequeues the next event and asserts it is a `.pathMismatch(...)`
    /// matching `predicate`. Fails otherwise.
    public func receivePathMismatch(
        _ predicate: (NavigationPathMismatchEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "NavigationTestStore.receivePathMismatch — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .pathMismatch(let event) = actual else {
            recordTestStoreIssue(
                "NavigationTestStore.receivePathMismatch — expected .pathMismatch, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(event) {
            recordTestStoreIssue(
                "NavigationTestStore.receivePathMismatch predicate failed.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    // MARK: - Completion

    /// Asserts and consumes events that are currently queued.
    ///
    /// This is a non-terminal checkpoint. Later store operations continue to
    /// enqueue events. Use `finish()` once all test work has completed.
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
    ///
    /// The first event emitted after this call reports an issue in either
    /// exhaustivity mode. Idempotent — subsequent calls and the automatic
    /// deinit check are suppressed.
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

    /// Drains any unasserted events without firing. Useful in `.off`
    /// exhaustivity mode when a section of a test is intentionally
    /// non-exhaustive.
    public func skipReceivedEvents() {
        queue.drain()
    }

    // MARK: - Internals

    private static func wrapConfiguration(
        _ original: NavigationStoreConfiguration<R>,
        queue: TestEventQueue<NavigationEvent<R>>
    ) -> NavigationStoreConfiguration<R> {
        var wrapped = original
        wrapped.onEvent = { @MainActor [queue] event in
            original.onEvent?(event)
            queue.enqueue(event)
        }
        return wrapped
    }
}
