// MARK: - ChildCoordinatorLifecycleSignalsTests.swift
// InnoRouterTests - 5.0 ChildCoordinator.lifecycleSignals routing.
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing

import InnoRouterSwiftUI

@MainActor
private final class SignalsChild: ChildCoordinator {
    typealias Result = Int
    var onFinish: (@MainActor @Sendable (Int) -> Void)?
    var onCancel: (@MainActor @Sendable () -> Void)?
    var lifecycleSignals: LifecycleSignals = LifecycleSignals()
    private(set) var parentDidCancelCount: Int = 0

    func parentDidCancel() {
        parentDidCancelCount += 1
    }
}

@Suite("ChildCoordinator.lifecycleSignals routing")
struct ChildCoordinatorLifecycleSignalsTests {

    @MainActor
    private func waitForCallbacks(on child: SignalsChild) async -> Bool {
        for _ in 0..<1_000 {
            if child.onFinish != nil, child.onCancel != nil {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @Test("caller cancellation fires both parentDidCancel() and lifecycleSignals.onParentCancel")
    @MainActor
    func parentCancel_firesBothSignals() async {
        let child = SignalsChild()

        var lifecycleFired = 0
        child.lifecycleSignals.onParentCancel = { lifecycleFired += 1 }

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        task.cancel()

        let result = await task.value

        #expect(result == nil)
        #expect(child.parentDidCancelCount == 1)
        #expect(lifecycleFired == 1)
    }

    @Test("a child without an installed lifecycleSignals handler still receives parentDidCancel()")
    @MainActor
    func parentCancel_whenSignalNotInstalled_doesNotCrash() async {
        let child = SignalsChild()
        // Do NOT install onParentCancel.

        let task = Task { @MainActor in
            await child.waitForResult()
        }
        #expect(await waitForCallbacks(on: child))
        task.cancel()

        _ = await task.value

        #expect(child.parentDidCancelCount == 1)
    }
}
