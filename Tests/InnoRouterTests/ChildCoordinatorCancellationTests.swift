// MARK: - ChildCoordinatorCancellationTests.swift
// InnoRouterTests - parent Task cancellation → ChildCoordinator.parentDidCancel
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import InnoRouterSwiftUI

/// Child that tracks `parentDidCancel` invocations.
@MainActor
private final class TrackingChild: ChildCoordinator {
    typealias Result = String

    var onFinish: (@MainActor @Sendable (String) -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?
    var lifecycleSignals: LifecycleSignals = LifecycleSignals()
    private(set) var parentDidCancelCount: Int = 0

    func parentDidCancel() {
        parentDidCancelCount += 1
    }
}

/// Default-conformance child — does NOT override `parentDidCancel`.
@MainActor
private final class DefaultChild: ChildCoordinator {
    typealias Result = Int

    var onFinish: (@MainActor @Sendable (Int) -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?
    var lifecycleSignals: LifecycleSignals = LifecycleSignals()
}

/// Child that owns its transient work directly instead of relying on a
/// framework task-tracking abstraction.
@MainActor
private final class TaskOwningChild: ChildCoordinator {
    typealias Result = Int

    var onFinish: (@MainActor @Sendable (Int) -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?
    var lifecycleSignals: LifecycleSignals = LifecycleSignals()
    private var workTask: Task<Void, Never>?

    func startWork() -> Task<Void, Never> {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        workTask = task
        return task
    }

    func parentDidCancel() {
        workTask?.cancel()
        workTask = nil
    }
}

@Suite("ChildCoordinator Cancellation Tests")
struct ChildCoordinatorCancellationTests {

    @MainActor
    private func waitForCallbacks<Child: ChildCoordinator>(
        on child: Child
    ) async -> Bool {
        for _ in 0..<1_000 {
            if child.onFinish != nil, child.onCancel != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @Test("Cancelling the calling Task invokes child.parentDidCancel() exactly once and resolves to nil")
    @MainActor
    func parentTaskCancellationTriggersParentDidCancel() async {
        let child = TrackingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        task.cancel()
        task.cancel()

        let result = await task.value
        #expect(result == nil)
        #expect(child.parentDidCancelCount == 1)
        #expect(child.onFinish == nil)
        #expect(child.onCancel == nil)
    }

    @Test("An already-cancelled caller still notifies the child exactly once")
    @MainActor
    func alreadyCancelledCallerTriggersParentDidCancel() async {
        let child = TrackingChild()

        // The test owns MainActor until `task.value` is awaited, so cancelling
        // here guarantees `waitForResult()` observes cancellation at entry.
        let task = Task { @MainActor in
            await child.waitForResult()
        }
        task.cancel()
        task.cancel()

        #expect(await task.value == nil)
        #expect(child.parentDidCancelCount == 1)
        #expect(child.onFinish == nil)
        #expect(child.onCancel == nil)
    }

    @Test("Normal finish path does NOT invoke parentDidCancel")
    @MainActor
    func normalFinishDoesNotInvokeParentDidCancel() async {
        let child = TrackingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        child.onFinish?("welcome")

        let result = await task.value
        #expect(result == "welcome")

        #expect(child.parentDidCancelCount == 0)
    }

    @Test("Child onCancel path does NOT invoke parentDidCancel (directional hooks are orthogonal)")
    @MainActor
    func childOnCancelDoesNotInvokeParentDidCancel() async {
        let child = TrackingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        child.onCancel?()

        let result = await task.value
        #expect(result == nil)

        #expect(child.parentDidCancelCount == 0)
    }

    @Test("Default ChildCoordinator conformance (no parentDidCancel override) still resolves to nil on cancellation")
    @MainActor
    func defaultConformanceRemainsCompatible() async {
        let child = DefaultChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        task.cancel()

        let result = await task.value
        #expect(result == nil)
    }

    @Test("A child can cancel its directly owned task from parentDidCancel")
    @MainActor
    func parentCancellationCancelsChildOwnedTask() async {
        let child = TaskOwningChild()
        let workTask = child.startWork()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        task.cancel()

        let result = await task.value
        await workTask.value

        #expect(result == nil)
        #expect(workTask.isCancelled)
    }

    @Test("Cancelling nested coordinator tasks notifies each matching child")
    @MainActor
    func cancellingNestedTasksNotifiesEachChild() async {
        let child = TrackingChild()
        let grandchild = TrackingChild()

        let childTask = Task { @MainActor in
            await child.waitForResult()
        }
        // Once `child` is active, start the independently retained
        // grandchild handoff. Coordinator-tree ownership remains app policy.
        let grandchildTask = Task { @MainActor in
            await grandchild.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        #expect(await waitForCallbacks(on: grandchild))

        // Coordinator-tree ownership is app policy. When the parent tears
        // down both placements, it explicitly cancels both task handles.
        grandchildTask.cancel()
        childTask.cancel()

        _ = await grandchildTask.value
        _ = await childTask.value

        #expect(child.parentDidCancelCount == 1)
        #expect(grandchild.parentDidCancelCount == 1)
    }

    @Test("A completed child result wins a later caller cancellation without firing parentDidCancel")
    @MainActor
    func finishWinsLaterCallerCancellation() async {
        let child = TrackingChild()

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))

        child.onFinish?("welcome")
        task.cancel()

        #expect(await task.value == "welcome")
        #expect(child.parentDidCancelCount == 0)
        #expect(child.onFinish == nil)
        #expect(child.onCancel == nil)
    }
}
