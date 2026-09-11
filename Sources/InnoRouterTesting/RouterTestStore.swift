// MARK: - RouterTestStore.swift
// InnoRouterTesting - canonical InnoRouter 6 test harness
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore
import InnoRouterSwiftUI

/// Host-less assertion harness for the macro-first `RouterStore` pipeline.
///
/// Production policies run unchanged. Every correlated lifecycle event is
/// buffered synchronously, so tests can send an action and consume the exact
/// `started → policyPrepared → committed/rejected` order without sleeps.
@MainActor
public final class RouterTestStore<R: Route> {
    let underlying: RouterStore<R>
    private let queue: TestEventQueue<RouterEvent<R>>
    let lifecycle: RouterTestRequestLifecycle<R>
    private let runtime: RouterTestRuntime?
    private let runtimeOwnerID: UUID?

    public init(
        initialState: RouterState<R> = .rootStack,
        configuration: RouterStoreConfiguration<R> = .init(),
        exhaustivity: TestExhaustivity = .strict,
        runtime: RouterTestRuntime? = nil
    ) {
        let queue = TestEventQueue<RouterEvent<R>>(
            storeName: "RouterTestStore",
            exhaustivity: exhaustivity
        )
        self.queue = queue
        let lifecycle = RouterTestRequestLifecycle<R>()
        self.lifecycle = lifecycle
        self.runtime = runtime
        let runtimeOwnerID = runtime.map { _ in UUID() }
        self.runtimeOwnerID = runtimeOwnerID

        var observedConfiguration = configuration
        if let runtime, let runtimeOwnerID {
            observedConfiguration.runtimeDependencies = runtime.dependencies(ownerID: runtimeOwnerID)
        }
        let originalDidQueueRequest = observedConfiguration.runtimeDependencies.didQueueRequest
        observedConfiguration.runtimeDependencies.didQueueRequest = { id in
            originalDidQueueRequest(id)
            lifecycle.observeQueued(id)
        }
        let originalOnEvent = configuration.onEvent
        observedConfiguration.onEvent = { event in
            originalOnEvent?(event)
            queue.enqueue(event)
            lifecycle.observe(event)
        }
        self.underlying = RouterStore(
            initialState: initialState,
            configuration: observedConfiguration
        )
    }

    public convenience init(
        initialPath: [R],
        configuration: RouterStoreConfiguration<R> = .init(),
        exhaustivity: TestExhaustivity = .strict,
        runtime: RouterTestRuntime? = nil
    ) {
        self.init(
            initialState: .rootStack(path: initialPath),
            configuration: configuration,
            exhaustivity: exhaustivity,
            runtime: runtime
        )
    }

    // Work around swiftlang/swift#90625 in Swift 6.3.x release builds.
    #if compiler(<6.4)
        @_optimize(none)
    #endif
    isolated deinit {
        _ = lifecycle.cancelAll()
        if let runtimeOwnerID { runtime?.clock.cancelAll(ownerID: runtimeOwnerID) }
        queue.finishAtDeinitialization(
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
    }

    public var state: RouterState<R> { underlying.state }
    public var revision: UInt64 { underlying.revision }
    public var store: RouterStore<R> { underlying }
    public var unassertedEvents: [RouterEvent<R>] { queue.remaining }

    /// Work that a strict finish must not leave unresolved.
    public var pendingWork: RouterTestPendingWork {
        RouterTestPendingWork(
            requests: lifecycle.pendingRequestCount,
            deferrals: underlying.deferredTransitions.count,
            timers: runtimeOwnerID.map { runtime?.clock.pendingSleepCount(ownerID: $0) ?? 0 } ?? 0,
            waiters: lifecycle.pendingWaiterCount
        )
    }

    func waitUntilPendingWaiterCount(_ count: Int) async {
        await lifecycle.waitUntilWaiterCount(count)
    }

    /// Performs an action through the production reduce/prepare/commit path.
    @discardableResult
    public func send(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await underlying.perform(action, context: context)
    }

    /// Starts a request without awaiting it and returns an exact lifecycle
    /// handle for overlap, cancellation, timeout, and queue tests.
    public func start(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) -> RouterTestRequest<R> {
        start(action, context: context, expectedRevision: nil)
    }

    package func start(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) -> RouterTestRequest<R> {
        let id = underlying.reserveTransitionID()
        let task = Task { @MainActor [underlying] in
            await underlying.perform(
                action,
                context: context,
                expectedRevision: expectedRevision,
                bypassesPolicies: false,
                startingPolicyIndex: 0,
                transitionID: id
            )
        }
        lifecycle.register(id: id, task: task)
        return RouterTestRequest(id: id, task: task, lifecycle: lifecycle)
    }

    func startHistoryNavigation(
        _ action: RouterAction<R>,
        target: RouterState<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) -> RouterTestRequest<R> {
        let id = underlying.reserveTransitionID()
        let task = Task { @MainActor [underlying] in
            await underlying.perform(
                action,
                context: context,
                expectedRevision: expectedRevision,
                bypassesPolicies: false,
                startingPolicyIndex: 0,
                transitionID: id,
                requestSemantics: .historyNavigation(target),
                deferredResumePreparation: { currentState, _ in
                    RouterHistory<R>.prepareNavigationMerge(target, into: currentState)
                }
            )
        }
        lifecycle.register(id: id, task: task)
        return RouterTestRequest(id: id, task: task, lifecycle: lifecycle)
    }

    /// Starts an explicit decision for one deferred production request and
    /// returns the same controllable lifecycle handle used by ordinary sends.
    public func resolveDeferred(
        _ deferralID: RouterDeferralID,
        with resolution: RouterDeferralResolution,
        resumeStrategy: RouterDeferralResumeStrategy = .requireUnchangedState
    ) -> RouterTestRequest<R> {
        let id = underlying.reserveTransitionID()
        let task = Task { @MainActor [underlying] in
            await underlying.resolveDeferred(
                deferralID,
                with: resolution,
                resumeStrategy: resumeStrategy,
                transitionID: id
            )
        }
        lifecycle.register(id: id, task: task)
        return RouterTestRequest(id: id, task: task, lifecycle: lifecycle)
    }

    /// Advances only the virtual clock supplied to this test store.
    public func advanceTime(by duration: Duration) {
        runtime?.clock.advance(by: duration)
    }

    /// Suspends until this store's virtual runtime has registered at least one
    /// timer. Returns `false` when the store has no virtual runtime.
    public func waitUntilTimeIsScheduled(_ count: Int = 1) async -> Bool {
        guard let runtime, let runtimeOwnerID else { return false }
        return await runtime.clock.waitUntilScheduled(count, ownerID: runtimeOwnerID)
    }

    /// Suspends until an observed production event satisfies `predicate`.
    /// Previously observed events are eligible, so callers cannot miss a fast
    /// transition between starting a request and installing the barrier.
    @discardableResult
    public func waitForEvent(
        where predicate: @escaping (RouterEvent<R>) -> Bool
    ) async -> RouterEvent<R>? {
        await lifecycle.waitForEvent(matching: predicate)
    }

    /// Applies an exact plan through the production pipeline.
    @discardableResult
    public func send(
        _ plan: RouterPlan<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await send(.apply(plan), context: context)
    }

    /// Consumes and compares the next exact event.
    public func receive(
        _ expected: RouterEvent<R>,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "RouterTestStore.receive(\(expected)) — queue is empty.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return
        }
        guard actual == expected else {
            recordTestStoreIssue(
                "RouterTestStore.receive mismatch. Expected: \(expected). Actual: \(actual).",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return
        }
    }

    /// Consumes the next event and evaluates an assertion predicate.
    @discardableResult
    public func receive(
        _ predicate: (RouterEvent<R>) -> Bool,
        failureMessage: @autoclosure () -> String = "predicate returned false",
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) -> RouterEvent<R>? {
        guard let actual = queue.dequeue() else {
            recordTestStoreIssue(
                "RouterTestStore.receive(predicate) — queue is empty.",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return nil
        }
        if !predicate(actual) {
            recordTestStoreIssue(
                "RouterTestStore.receive(predicate) failed for \(actual): \(failureMessage())",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
        return actual
    }

    public func receiveStarted(
        _ predicate: (RouterTransition<R>) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receive({ event in
            guard case .started(let transition) = event else { return false }
            return predicate(transition)
        }, failureMessage: "expected .started", fileID: fileID, filePath: filePath, line: line, column: column)
    }

    public func receiveCommitted(
        _ predicate: (RouterState<R>, UInt64) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receive({ event in
            guard case .committed(_, _, let after, let revision, _) = event else { return false }
            return predicate(after, revision)
        }, failureMessage: "expected .committed", fileID: fileID, filePath: filePath, line: line, column: column)
    }

    public func receiveRejected(
        _ predicate: (RouterRejectionReason) -> Bool = { _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receive({ event in
            guard case .rejected(_, _, _, let reason, _) = event else { return false }
            return predicate(reason)
        }, failureMessage: "expected .rejected", fileID: fileID, filePath: filePath, line: line, column: column)
    }

    public func receiveUnchanged(
        _ predicate: (RouterState<R>, UInt64) -> Bool = { _, _ in true },
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        receive({ event in
            guard case .unchanged(_, let state, let revision, _) = event else { return false }
            return predicate(state, revision)
        }, failureMessage: "expected .unchanged", fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// Compares the complete canonical state with one expected value.
    public func assertState(
        _ expected: RouterState<R>,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) {
        guard state == expected else {
            recordTestStoreIssue(
                "RouterTestStore.assertState mismatch. Expected: \(expected). Actual: \(state).",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            return
        }
    }

    public func skipReceivedEvents() {
        queue.drain()
    }

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

    public func finish(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async {
        let pending = pendingWork
        if pending.isEmpty == false {
            recordTestStoreIssue(
                "RouterTestStore.finish() found pending work: \(pending.requests) request(s), \(pending.deferrals) deferral(s), \(pending.timers) timer(s), \(pending.waiters) waiter(s).",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
        let tasks = lifecycle.cancelAll()
        if let runtimeOwnerID { runtime?.clock.cancelAll(ownerID: runtimeOwnerID) }
        for task in tasks { _ = await task.value }
        for deferral in underlying.deferredTransitions {
            _ = await underlying.cancelDeferred(deferral.id)
        }
        queue.finish(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
}

public extension RouterTestStore where R: Codable {
    /// Encodes the test store through the production snapshot codec.
    func snapshot(using codec: RouterSnapshotCodec<R>) async throws -> Data {
        try await underlying.snapshot(using: codec)
    }

    /// Restores through the production policy and transition-context path.
    @discardableResult
    func restore(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        recovery: RouterSnapshotRecoveryPolicy<R> = .fail
    ) async throws -> RouterRestorationOutcome<R> {
        try await underlying.restore(
            from: data,
            using: codec,
            recovery: recovery
        )
    }

    /// Exercises app-validated partial restoration with the same virtual
    /// runtime used by policy, deferral, and cancellation tests.
    @discardableResult
    func restorePartially(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        validator: RouterPartialRestorationValidator<R>,
        validationTimeout: Duration? = nil,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterPartialRestorationOutcome<R> {
        try await underlying.restorePartially(
            from: data,
            using: codec,
            validator: validator,
            validationTimeout: validationTimeout,
            expectedRevision: expectedRevision
        )
    }
}
