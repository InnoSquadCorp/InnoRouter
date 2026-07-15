// MARK: - ChildCoordinatorCancellationTests.swift
// InnoRouterTests - parent Task cancellation → ChildCoordinator.parentDidCancel
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import SwiftUI
import InnoRouter
import InnoRouterSwiftUI

private enum CancelRoute: Route {
    case root
}

@MainActor
private final class CancelParent: Coordinator {
    typealias RouteType = CancelRoute
    typealias Destination = EmptyView

    let store = NavigationStore<CancelRoute>()

    @ViewBuilder
    func destination(for route: CancelRoute) -> EmptyView {
        EmptyView()
    }
}

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

    @Test("Cancelling the parent Task invokes child.parentDidCancel() exactly once and the task resolves to nil")
    @MainActor
    func parentTaskCancellationTriggersParentDidCancel() async {
        let parent = CancelParent()
        let child = TrackingChild()

        let task = parent.push(child: child)
        task.cancel()

        let result = await task.value
        #expect(result == nil)

        // Give the onCancel handler's Task { @MainActor in ... } hop a
        // chance to land before reading the counter.
        await Task.yield()
        await Task.yield()
        #expect(child.parentDidCancelCount == 1)
    }

    @Test("Normal finish path does NOT invoke parentDidCancel")
    @MainActor
    func normalFinishDoesNotInvokeParentDidCancel() async {
        let parent = CancelParent()
        let child = TrackingChild()

        let task = parent.push(child: child)
        child.onFinish?("welcome")

        let result = await task.value
        #expect(result == "welcome")

        await Task.yield()
        await Task.yield()
        #expect(child.parentDidCancelCount == 0)
    }

    @Test("Child onCancel path does NOT invoke parentDidCancel (directional hooks are orthogonal)")
    @MainActor
    func childOnCancelDoesNotInvokeParentDidCancel() async {
        let parent = CancelParent()
        let child = TrackingChild()

        let task = parent.push(child: child)
        child.onCancel?()

        let result = await task.value
        #expect(result == nil)

        await Task.yield()
        await Task.yield()
        #expect(child.parentDidCancelCount == 0)
    }

    @Test("Default ChildCoordinator conformance (no parentDidCancel override) still resolves to nil on cancellation")
    @MainActor
    func defaultConformanceRemainsCompatible() async {
        let parent = CancelParent()
        let child = DefaultChild()

        let task = parent.push(child: child)
        task.cancel()

        let result = await task.value
        #expect(result == nil)
    }

    @Test("A child can cancel its directly owned task from parentDidCancel")
    @MainActor
    func parentCancellationCancelsChildOwnedTask() async {
        let parent = CancelParent()
        let child = TaskOwningChild()
        let workTask = child.startWork()

        let task = parent.push(child: child)
        task.cancel()

        let result = await task.value
        await workTask.value

        #expect(result == nil)
        #expect(workTask.isCancelled)
    }

    @Test("Cancelling nested coordinator tasks notifies each matching child")
    @MainActor
    func cancellingNestedTasksNotifiesEachChild() async {
        let rootParent = CancelParent()
        let child = TrackingChild()
        let grandchild = TrackingChild()

        let childTask = rootParent.push(child: child)
        // Once `child` is active, spawn the grandchild under it. The
        // grandchild is itself reachable through child's push(child:)
        // helper — any Coordinator conformer qualifies.
        let intermediateParent = CancelParent()
        let grandchildTask = intermediateParent.push(child: grandchild)

        // Coordinator-tree ownership is app policy. When the parent tears
        // down both placements, it explicitly cancels both task handles.
        grandchildTask.cancel()
        childTask.cancel()

        _ = await grandchildTask.value
        _ = await childTask.value

        await Task.yield()
        await Task.yield()
        #expect(child.parentDidCancelCount == 1)
        #expect(grandchild.parentDidCancelCount == 1)
    }
}
