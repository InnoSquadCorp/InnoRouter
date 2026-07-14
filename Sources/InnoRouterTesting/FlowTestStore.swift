// MARK: - FlowTestStore.swift
// InnoRouterTesting - host-less flow test harness
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore
import InnoRouterSwiftUI

/// A host-less, Swift-Testing native assertion harness for `FlowStore`.
///
/// `FlowTestStore` wraps a private `FlowStore<R>` and subscribes to:
///
/// - the FlowStore-level `onPathChanged` and `onIntentRejected` callbacks,
/// - every `NavigationStoreConfiguration` observation hook on the inner
///   navigation store,
/// - every `ModalStoreConfiguration` observation hook on the inner modal
///   store.
///
/// All events land in a single FIFO queue and preserve their real emission
/// order. This lets a test assert, for example, that a single
/// `.send(.presentSheet(...))` actually reached the modal store's middleware
/// pipeline and then updated the path, or — with a blocking middleware —
/// that the navigation store was never touched.
///
/// ```swift
/// let store = FlowTestStore<AppRoute>()
/// store.send(.push(.home))
/// store.receive(.navigation(.changed(from: .init(), to: ...)))
/// store.receive(.pathChanged(old: [], new: [.push(.home)]))
/// ```
@MainActor
public final class FlowTestStore<R: Route> {

    // MARK: - Stored

    private let underlying: FlowStore<R>
    private let queue: TestEventQueue<FlowTestEvent<R>>

    // MARK: - Init

    public init(
        initial: [RouteStep<R>] = [],
        configuration: FlowStoreConfiguration<R> = .init(),
        exhaustivity: TestExhaustivity = .strict
    ) {
        let queue = TestEventQueue<FlowTestEvent<R>>(
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

    // MARK: - Accessors

    public var store: FlowStore<R> {
        underlying
    }

    public var path: [RouteStep<R>] {
        underlying.path
    }

    public var unassertedEvents: [FlowTestEvent<R>] {
        queue.remaining
    }

    // MARK: - Execution

    public func send(_ intent: FlowIntent<R>) {
        underlying.send(intent)
    }

    @discardableResult
    public func apply(_ plan: FlowPlan<R>) -> FlowPlanApplyResult<R> {
        underlying.apply(plan)
    }

    // MARK: - Assertion

    public func receive(
        _ expected: FlowTestEvent<R>,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receive(\(expected)) — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if actual != expected {
            recordTestStoreIssue(
                """
                FlowTestStore.receive mismatch.
                Expected: \(expected)
                Actual:   \(actual)
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receivePathChanged(
        _ predicate: ([RouteStep<R>], [RouteStep<R>]) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receivePathChanged — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .pathChanged(let old, let new) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receivePathChanged — expected .pathChanged, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(old, new) {
            recordTestStoreIssue(
                "FlowTestStore.receivePathChanged predicate failed.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receiveIntentRejected(
        intent: FlowIntent<R>,
        reason: FlowRejectionReason,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receiveIntentRejected — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .intentRejected(let observedIntent, let observedReason) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receiveIntentRejected — expected .intentRejected, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if observedIntent != intent || observedReason != reason {
            recordTestStoreIssue(
                """
                FlowTestStore.receiveIntentRejected mismatch.
                Expected: (\(intent), \(reason))
                Actual:   (\(observedIntent), \(observedReason))
                """,
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receiveNavigation(
        _ predicate: (NavigationTestEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receiveNavigation — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .navigation(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receiveNavigation — expected .navigation, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(event) {
            recordTestStoreIssue(
                "FlowTestStore.receiveNavigation predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    public func receiveModal(
        _ predicate: (ModalTestEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.receiveModal — queue is empty.",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .modal(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.receiveModal — expected .modal, got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !predicate(event) {
            recordTestStoreIssue(
                "FlowTestStore.receiveModal predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    // MARK: - Typed sub-event receivers
    //
    // The predicate-based `receiveNavigation` / `receiveModal` above remain
    // the escape hatch for arbitrary matching. The helpers below are
    // case-specific overloads: each dequeues the next event, asserts that
    // (a) the wrapper case is `.navigation` / `.modal`, (b) the inner
    // sub-case matches, and (c) any user-supplied predicate over the
    // payload returns true. The `Issue.record` message names the expected
    // sub-case explicitly, which makes failures readable in test output
    // without callers having to embed the case name in their predicates.

    // Asserts the next queued event is `.navigation(.changed(from:to:))`.
    // The optional predicate payload check defaults to accepting any
    // `(from, to)` pair; without it the helper only verifies the case
    // shape. The trailing `fileID` / `filePath` / `line` / `column`
    // parameters carry the call-site location into Swift Testing's
    // `Issue.record(...)` and are intended to use their `#`-literal
    // defaults — callers do not pass them explicitly. (Non-doc comment:
    // the predicate-based `receiveNavigation` overload above is also
    // intentionally undocumented in DocC because adding `- Parameter`
    // sections for the four source-location defaults would noise the
    // generated reference for every overload.)
    public func receiveNavigationChanged(
        _ predicate: (RouteStack<R>, RouteStack<R>) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationChanged",
            expected: ".changed",
            extract: { event -> (from: RouteStack<R>, to: RouteStack<R>)? in
                guard case .changed(let from, let to) = event else { return nil }
                return (from, to)
            },
            check: { predicate($0.from, $0.to) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.navigation(.batchExecuted(_))`.
    public func receiveNavigationBatch(
        _ predicate: (NavigationBatchResult<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationBatch",
            expected: ".batchExecuted",
            extract: { event -> NavigationBatchResult<R>? in
                guard case .batchExecuted(let result) = event else { return nil }
                return result
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.navigation(.transactionExecuted(_))`.
    public func receiveNavigationTransaction(
        _ predicate: (NavigationTransactionResult<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationTransaction",
            expected: ".transactionExecuted",
            extract: { event -> NavigationTransactionResult<R>? in
                guard case .transactionExecuted(let result) = event else { return nil }
                return result
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.navigation(.middlewareMutation(_))`.
    public func receiveNavigationMiddlewareMutation(
        _ predicate: (MiddlewareMutationEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationMiddlewareMutation",
            expected: ".middlewareMutation",
            extract: { event -> MiddlewareMutationEvent<R>? in
                guard case .middlewareMutation(let mutation) = event else { return nil }
                return mutation
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.navigation(.pathMismatch(_))`.
    public func receiveNavigationPathMismatch(
        _ predicate: (NavigationPathMismatchEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveNavigationCase(
            label: "receiveNavigationPathMismatch",
            expected: ".pathMismatch",
            extract: { event -> NavigationPathMismatchEvent<R>? in
                guard case .pathMismatch(let mismatch) = event else { return nil }
                return mismatch
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.modal(.presented(_))`.
    public func receiveModalPresented(
        _ predicate: (ModalPresentation<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalPresented",
            expected: ".presented",
            extract: { event -> ModalPresentation<R>? in
                guard case .presented(let presentation) = event else { return nil }
                return presentation
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.modal(.dismissed(_, reason:))`.
    public func receiveModalDismissed(
        _ predicate: (ModalPresentation<R>, ModalDismissalReason) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalDismissed",
            expected: ".dismissed",
            extract: { event -> (presentation: ModalPresentation<R>, reason: ModalDismissalReason)? in
                guard case .dismissed(let presentation, let reason) = event else { return nil }
                return (presentation, reason)
            },
            check: { predicate($0.presentation, $0.reason) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.modal(.queueChanged(old:new:))`.
    public func receiveModalQueueChanged(
        _ predicate: ([ModalPresentation<R>], [ModalPresentation<R>]) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalQueueChanged",
            expected: ".queueChanged",
            extract: { event -> (old: [ModalPresentation<R>], new: [ModalPresentation<R>])? in
                guard case .queueChanged(let old, let new) = event else { return nil }
                return (old, new)
            },
            check: { predicate($0.old, $0.new) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.modal(.commandIntercepted(command:result:))`.
    public func receiveModalCommandIntercepted(
        _ predicate: (ModalCommand<R>, ModalExecutionResult<R>) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalCommandIntercepted",
            expected: ".commandIntercepted",
            extract: { event -> (command: ModalCommand<R>, result: ModalExecutionResult<R>)? in
                guard case .commandIntercepted(let command, let result) = event else { return nil }
                return (command, result)
            },
            check: { predicate($0.command, $0.result) },
            fileID: fileID, filePath: filePath, line: line, column: column
        )
    }

    // Asserts the next queued event is `.modal(.middlewareMutation(_))`.
    public func receiveModalMiddlewareMutation(
        _ predicate: (ModalMiddlewareMutationEvent<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receiveModalCase(
            label: "receiveModalMiddlewareMutation",
            expected: ".middlewareMutation",
            extract: { event -> ModalMiddlewareMutationEvent<R>? in
                guard case .middlewareMutation(let mutation) = event else { return nil }
                return mutation
            },
            check: predicate,
            fileID: fileID, filePath: filePath, line: line, column: column
        )
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

    private func receiveNavigationCase<Payload>(
        label: String,
        expected: String,
        extract: (NavigationTestEvent<R>) -> Payload?,
        check: (Payload) -> Bool,
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — queue is empty (expected .navigation(\(expected))).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .navigation(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected .navigation(\(expected)), got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard let payload = extract(event) else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected \(expected), got \(Self.navigationCaseName(event)) — \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !check(payload) {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — payload predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    private func receiveModalCase<Payload>(
        label: String,
        expected: String,
        extract: (ModalTestEvent<R>) -> Payload?,
        check: (Payload) -> Bool,
        fileID: String,
        filePath: String,
        line: Int,
        column: Int
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — queue is empty (expected .modal(\(expected))).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard case .modal(let event) = actual else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected .modal(\(expected)), got \(actual).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        guard let payload = extract(event) else {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — expected \(expected), got \(Self.modalCaseName(event)) — \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
            return
        }
        if !check(payload) {
            recordTestStoreIssue(
                "FlowTestStore.\(label) — payload predicate failed for \(event).",
                fileID: fileID, filePath: filePath, line: line, column: column
            )
        }
    }

    private static func navigationCaseName(_ event: NavigationTestEvent<R>) -> String {
        switch event {
        case .changed: return ".changed"
        case .batchExecuted: return ".batchExecuted"
        case .transactionExecuted: return ".transactionExecuted"
        case .middlewareMutation: return ".middlewareMutation"
        case .pathMismatch: return ".pathMismatch"
        }
    }

    private static func modalCaseName(_ event: ModalTestEvent<R>) -> String {
        switch event {
        case .presented: return ".presented"
        case .dismissed: return ".dismissed"
        case .replaced: return ".replaced"
        case .queueChanged: return ".queueChanged"
        case .commandIntercepted: return ".commandIntercepted"
        case .middlewareMutation: return ".middlewareMutation"
        }
    }

    private static func wrapConfiguration(
        _ original: FlowStoreConfiguration<R>,
        queue: TestEventQueue<FlowTestEvent<R>>
    ) -> FlowStoreConfiguration<R> {
        var wrapped = original
        wrapped.navigation = Self.wrapNavigationConfiguration(
            original.navigation,
            queue: queue
        )
        wrapped.modal = Self.wrapModalConfiguration(
            original.modal,
            queue: queue
        )
        wrapped.onPathChanged = { @MainActor [queue] old, new in
            original.onPathChanged?(old, new)
            queue.enqueue(.pathChanged(old: old, new: new))
        }
        wrapped.onIntentRejected = { @MainActor [queue] intent, reason in
            original.onIntentRejected?(intent, reason)
            queue.enqueue(.intentRejected(intent, reason))
        }
        return wrapped
    }

    private static func wrapNavigationConfiguration(
        _ original: NavigationStoreConfiguration<R>,
        queue: TestEventQueue<FlowTestEvent<R>>
    ) -> NavigationStoreConfiguration<R> {
        var wrapped = original
        wrapped.onChange = { @MainActor [queue] old, new in
            original.onChange?(old, new)
            queue.enqueue(.navigation(.changed(from: old, to: new)))
        }
        wrapped.onBatchExecuted = { @MainActor [queue] result in
            original.onBatchExecuted?(result)
            queue.enqueue(.navigation(.batchExecuted(result)))
        }
        wrapped.onTransactionExecuted = { @MainActor [queue] result in
            original.onTransactionExecuted?(result)
            queue.enqueue(.navigation(.transactionExecuted(result)))
        }
        wrapped.onMiddlewareMutation = { @MainActor [queue] event in
            original.onMiddlewareMutation?(event)
            queue.enqueue(.navigation(.middlewareMutation(event)))
        }
        wrapped.onPathMismatch = { @MainActor [queue] event in
            original.onPathMismatch?(event)
            queue.enqueue(.navigation(.pathMismatch(event)))
        }
        return wrapped
    }

    private static func wrapModalConfiguration(
        _ original: ModalStoreConfiguration<R>,
        queue: TestEventQueue<FlowTestEvent<R>>
    ) -> ModalStoreConfiguration<R> {
        var wrapped = original
        wrapped.onPresented = { @MainActor [queue] presentation in
            original.onPresented?(presentation)
            queue.enqueue(.modal(.presented(presentation)))
        }
        wrapped.onDismissed = { @MainActor [queue] presentation, reason in
            original.onDismissed?(presentation, reason)
            queue.enqueue(.modal(.dismissed(presentation, reason: reason)))
        }
        wrapped.onReplaced = { @MainActor [queue] old, new in
            original.onReplaced?(old, new)
            queue.enqueue(.modal(.replaced(old: old, new: new)))
        }
        wrapped.onQueueChanged = { @MainActor [queue] old, new in
            original.onQueueChanged?(old, new)
            queue.enqueue(.modal(.queueChanged(old: old, new: new)))
        }
        wrapped.onMiddlewareMutation = { @MainActor [queue] event in
            original.onMiddlewareMutation?(event)
            queue.enqueue(.modal(.middlewareMutation(event)))
        }
        wrapped.onCommandIntercepted = { @MainActor [queue] command, result in
            original.onCommandIntercepted?(command, result)
            queue.enqueue(.modal(.commandIntercepted(command: command, result: result)))
        }
        return wrapped
    }
}
