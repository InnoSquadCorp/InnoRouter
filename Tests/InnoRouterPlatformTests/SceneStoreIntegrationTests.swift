// MARK: - SceneStoreIntegrationTests.swift
// InnoRouterPlatformTests — integration coverage for the three visionOS SceneStore hardening
// paths. Exercises SceneStore + SceneDispatchDriver end-to-end via
// mocked environment closures, without requiring a live SwiftUI view
// hierarchy. Scene types are #if os(visionOS), so this test file is
// similarly gated and runs on the visionOS CI leg.
// Copyright © 2026 Inno Squad. All rights reserved.

#if os(visionOS)

import Foundation
import SwiftUI
import Testing

@testable import InnoRouterSpatial
import InnoRouterCore

private enum SpatialRoute: String, Route {
    case main
    case theatre
}

private func makeRegistry() -> SceneRegistry<SpatialRoute> {
    SceneRegistry(
        .window(.main, id: "main"),
        .immersive(.theatre, id: "theatre", style: .mixed)
    )
}

private actor AsyncSignal {
    private var didSignal = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !didSignal else { return }
        didSignal = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !didSignal else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor AsyncCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func read() -> Int {
        value
    }
}

private actor DuplicateHostRejectionCounter<R: Route> {
    private var count = 0

    func record(_ event: SceneEvent<R>) {
        if case .hostRegistrationRejected(.duplicateHostRegistration) = event {
            count += 1
        }
    }

    func read() -> Int {
        count
    }
}

/// Collects the first event matching `predicate` or returns nil after
/// `timeout` seconds. Used to assert that a specific rejection or
/// registration event reaches subscribers.
@MainActor
private func collectEvent<R: Route>(
    from store: SceneStore<R>,
    timeoutSeconds: Double = 2.0,
    where predicate: @escaping @Sendable (SceneEvent<R>) -> Bool
) async -> SceneEvent<R>? {
    let events = store.events
    let deadlineNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)

    return await withTaskGroup(of: SceneEvent<R>?.self) { group in
        group.addTask {
            for await event in events {
                if predicate(event) {
                    return event
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: deadlineNanoseconds)
            return nil
        }

        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? nil
    }
}

@Suite("SceneStore integration tests", .tags(.integration))
struct SceneStoreIntegrationTests {

    // MARK: - Hardening path 1: fallback anchor cannot dispatch cross-scene opens

    @Test("Fallback anchor rejects cross-scene open with .fallbackCannotDispatch")
    @MainActor
    func fallbackAnchorRejectsCrossSceneOpen() async throws {
        let store = SceneStore<SpatialRoute>()
        let scenes = makeRegistry()
        let theatreDeclaration = try #require(scenes.declaration(for: .theatre))

        // Only a fallback anchor is registered. It is attached to
        // `.theatre`, so a pending `openWindow(.main)` must be refused.
        let anchorToken = UUID()
        store.registerFallbackDispatcher(anchorToken)

        let mainWindow = store.openWindow(.main)

        let driver = SceneDispatchDriver<SpatialRoute>(
            store: store,
            scenes: scenes,
            dispatcherToken: anchorToken,
            capability: .fallbackAnchor(
                attachedTo: theatreDeclaration.presentation()
            ),
            openWindow: { _, _ in
                Issue.record("openWindow must not be called on a cross-scene fallback dispatch")
            },
            openImmersiveSpace: { _ in
                Issue.record("openImmersiveSpace must not be called")
                return .userCancelled
            },
            dismissImmersiveSpace: {
                Issue.record("dismissImmersiveSpace must not be called")
            },
            dismissWindow: { _, _ in
                Issue.record("dismissWindow must not be called")
            }
        )

        let collectTask = Task { @MainActor in
            await collectEvent(from: store) { event in
                if case .rejected(_, .fallbackCannotDispatch) = event {
                    return true
                }
                return false
            }
        }

        await driver.run()
        let collected = await collectTask.value

        #expect(collected != nil)
        if case .rejected(let intent, .fallbackCannotDispatch)? = collected {
            #expect(intent == .open(mainWindow))
        }
        #expect(store.currentScene == nil)
    }

    @Test("Fallback anchor rejects same-route opens for a different window instance")
    @MainActor
    func fallbackAnchorRejectsDifferentWindowInstanceWithSameRoute() async throws {
        let store = SceneStore<SpatialRoute>()
        let scenes = makeRegistry()
        let mainDeclaration = try #require(scenes.declaration(for: .main))
        let attachedWindow = mainDeclaration.presentation(id: UUID())

        store.attachDeclaredScene(attachedWindow)

        let anchorToken = UUID()
        store.registerFallbackDispatcher(anchorToken)

        let requestedWindow = store.openWindow(.main)
        #expect(requestedWindow != attachedWindow)

        let driver = SceneDispatchDriver<SpatialRoute>(
            store: store,
            scenes: scenes,
            dispatcherToken: anchorToken,
            capability: .fallbackAnchor(attachedTo: attachedWindow),
            openWindow: { _, _ in
                Issue.record("openWindow must not be called for a different window instance")
            },
            openImmersiveSpace: { _ in
                Issue.record("openImmersiveSpace must not be called")
                return .userCancelled
            },
            dismissImmersiveSpace: {
                Issue.record("dismissImmersiveSpace must not be called")
            },
            dismissWindow: { _, _ in
                Issue.record("dismissWindow must not be called")
            }
        )

        let collectTask = Task { @MainActor in
            await collectEvent(from: store) { event in
                if case .rejected(_, .fallbackCannotDispatch) = event {
                    return true
                }
                return false
            }
        }

        await driver.run()
        let collected = await collectTask.value

        #expect(collected != nil)
        if case .rejected(let intent, .fallbackCannotDispatch)? = collected {
            #expect(intent == .open(requestedWindow))
        }
        #expect(store.currentScene == attachedWindow)
        #expect(store.activeScenes == [attachedWindow])
    }

    // MARK: - Hardening path 2: duplicate SceneHost registration does not crash

    @Test("Duplicate SceneHost registration is recoverable and broadcasts .duplicateHostRegistration")
    @MainActor
    func duplicateHostRegistrationIsRecoverable() async {
        let store = SceneStore<SpatialRoute>()

        let collectTask = Task { @MainActor in
            await collectEvent(from: store) { event in
                if case .hostRegistrationRejected(.duplicateHostRegistration) = event {
                    return true
                }
                return false
            }
        }

        let firstToken = UUID()
        let secondToken = UUID()

        let firstRegistered = store.registerDispatcherHost(firstToken)
        let secondRegistered = store.registerDispatcherHost(secondToken)

        #expect(firstRegistered == true)
        #expect(secondRegistered == false)

        let collected = await collectTask.value
        #expect(collected != nil)
    }

    @Test("Dormant SceneHost retries only after dispatcher ownership changes")
    @MainActor
    func dormantSceneHostRetriesOnlyAfterDispatcherChanges() async {
        let store = SceneStore<SpatialRoute>()
        let rejectionCounter = DuplicateHostRejectionCounter<SpatialRoute>()
        let attachedPresentation = ScenePresentation<SpatialRoute>.window(.main)
        let primaryRegistration = SceneHostRegistration(
            store: store,
            dispatcherToken: UUID(),
            attachedPresentation: attachedPresentation
        )
        let dormantRegistration = SceneHostRegistration(
            store: store,
            dispatcherToken: UUID(),
            attachedPresentation: attachedPresentation
        )

        let eventTask = Task { @MainActor in
            for await event in store.events {
                await rejectionCounter.record(event)
            }
        }
        defer { eventTask.cancel() }

        await Task.yield()

        #expect(primaryRegistration.activate() == true)
        await Task.yield()
        #expect(await rejectionCounter.read() == 0)

        var isDormant = !dormantRegistration.activate()
        #expect(isDormant == true)
        await Task.yield()
        #expect(await rejectionCounter.read() == 1)

        var spawnCount = 0
        for _ in 0..<3 {
            handleSceneHostSignal(
                .dispatchRequested,
                isDormant: &isDormant,
                registration: dormantRegistration,
                spawnDispatchTask: {
                    spawnCount += 1
                }
            )
            await Task.yield()
        }

        #expect(spawnCount == 0)
        #expect(isDormant == true)
        #expect(await rejectionCounter.read() == 1)

        primaryRegistration.deactivateIfOwned()
        await Task.yield()

        handleSceneHostSignal(
            .dispatcherChanged,
            isDormant: &isDormant,
            registration: dormantRegistration,
            spawnDispatchTask: {
                spawnCount += 1
            }
        )
        await Task.yield()

        #expect(isDormant == false)
        #expect(spawnCount == 1)
        #expect(await rejectionCounter.read() == 1)
    }

    @Test("Replacement host can take over and dismiss its attached window after the original host unregisters")
    @MainActor
    func replacementHostCanTakeOverAttachedSceneInventory() async throws {
        let store = SceneStore<SpatialRoute>()
        let scenes = makeRegistry()
        let mainDeclaration = try #require(scenes.declaration(for: .main))
        let mainWindowID = UUID()
        let mainPresentation = mainDeclaration.presentation(id: mainWindowID)

        let firstRegistration = SceneHostRegistration(
            store: store,
            dispatcherToken: UUID(),
            attachedPresentation: mainPresentation
        )
        let replacementRegistration = SceneHostRegistration(
            store: store,
            dispatcherToken: UUID(),
            attachedPresentation: mainPresentation
        )

        #expect(firstRegistration.activate() == true)
        #expect(store.currentScene == mainPresentation)
        #expect(store.dispatcherSignal == 1)

        #expect(replacementRegistration.activate() == false)
        #expect(store.currentScene == mainPresentation)
        #expect(store.dispatcherSignal == 1)

        firstRegistration.deactivateIfOwned()
        #expect(store.currentScene == nil)
        #expect(store.dispatcherSignal == 2)

        #expect(replacementRegistration.activate() == true)
        #expect(store.currentScene == mainPresentation)
        #expect(store.dispatcherSignal == 3)

        store.dismissWindow(mainPresentation)

        var dismissedWindowIDs: [String] = []
        var dismissedWindowValues: [UUID] = []
        let driver = SceneDispatchDriver<SpatialRoute>(
            store: store,
            scenes: scenes,
            dispatcherToken: replacementRegistration.dispatcherToken,
            capability: .primaryHost,
            openWindow: { _, _ in
                Issue.record("openWindow must not be called while dismissing the attached host scene")
            },
            openImmersiveSpace: { _ in
                Issue.record("openImmersiveSpace must not be called while dismissing the attached host scene")
                return .userCancelled
            },
            dismissImmersiveSpace: {
                Issue.record("dismissImmersiveSpace must not be called while dismissing a window")
            },
            dismissWindow: { id, value in
                dismissedWindowIDs.append(id)
                dismissedWindowValues.append(value)
            }
        )

        await driver.run()

        #expect(dismissedWindowIDs == ["main"])
        #expect(dismissedWindowValues == [mainWindowID])
        #expect(store.currentScene == nil)
    }

    // MARK: - Hardening path 3: dispatch Task cancellation abandons the claim

    @Test("Cancelling the dispatch task abandons the claim with .hostTornDownDuringDispatch")
    @MainActor
    func dispatchTaskCancellationAbandonsClaim() async throws {
        let store = SceneStore<SpatialRoute>()
        let scenes = makeRegistry()
        let openEntered = AsyncSignal()
        let dismissCount = AsyncCounter()

        let hostToken = UUID()
        _ = store.registerDispatcherHost(hostToken)

        store.openImmersive(.theatre, style: .mixed)

        let driver = SceneDispatchDriver<SpatialRoute>(
            store: store,
            scenes: scenes,
            dispatcherToken: hostToken,
            capability: .primaryHost,
            openWindow: { _, _ in
                Issue.record("openWindow must not be called in the immersive path")
            },
            openImmersiveSpace: { _ in
                await openEntered.signal()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .opened
            },
            dismissImmersiveSpace: {
                await dismissCount.increment()
            },
            dismissWindow: { _, _ in }
        )

        let collectTask = Task { @MainActor in
            await collectEvent(from: store) { event in
                if case .rejected(_, .hostTornDownDuringDispatch) = event {
                    return true
                }
                return false
            }
        }

        let driverTask = Task { @MainActor in
            await driver.run()
        }

        await openEntered.wait()
        driverTask.cancel()

        _ = await driverTask.value
        let collected = await collectTask.value

        #expect(collected != nil)
        if case .rejected(let intent, .hostTornDownDuringDispatch)? = collected {
            #expect(intent == .open(.immersive(.theatre, style: .mixed)))
        }
        #expect(await dismissCount.read() == 1)
        #expect(store.currentScene == nil)
    }

    @Test("Cancelling an already-active immersive reopen does not dismiss the live scene")
    @MainActor
    func cancelledDuplicateImmersiveReopenDoesNotDismissActiveScene() async throws {
        let store = SceneStore<SpatialRoute>()
        let scenes = makeRegistry()
        let theatreDeclaration = try #require(scenes.declaration(for: .theatre))
        let theatrePresentation = theatreDeclaration.presentation()
        let openEntered = AsyncSignal()
        let dismissCount = AsyncCounter()

        let hostToken = UUID()
        _ = store.registerDispatcherHost(hostToken)
        store.attachDeclaredScene(theatrePresentation)

        store.openImmersive(.theatre, style: .mixed)

        let driver = SceneDispatchDriver<SpatialRoute>(
            store: store,
            scenes: scenes,
            dispatcherToken: hostToken,
            capability: .primaryHost,
            openWindow: { _, _ in
                Issue.record("openWindow must not be called in the immersive path")
            },
            openImmersiveSpace: { _ in
                await openEntered.signal()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return .opened
            },
            dismissImmersiveSpace: {
                await dismissCount.increment()
            },
            dismissWindow: { _, _ in }
        )

        let collectTask = Task { @MainActor in
            await collectEvent(from: store) { event in
                if case .rejected(_, .hostTornDownDuringDispatch) = event {
                    return true
                }
                return false
            }
        }

        let driverTask = Task { @MainActor in
            await driver.run()
        }

        await openEntered.wait()
        driverTask.cancel()

        _ = await driverTask.value
        let collected = await collectTask.value

        #expect(collected != nil)
        if case .rejected(let intent, .hostTornDownDuringDispatch)? = collected {
            #expect(intent == .open(.immersive(.theatre, style: .mixed)))
        }
        #expect(await dismissCount.read() == 0)
        #expect(store.currentScene == theatrePresentation)
    }
}

#endif
