// MARK: - NavigationMiddlewareRegistryTests.swift
// InnoRouterTests - NavigationMiddlewareRegistry invariants and edge cases
// Copyright © 2025 Inno Squad. All rights reserved.

import Testing
import Foundation
import InnoRouterCore
@testable import InnoRouterSwiftUI

// MARK: - Local fixtures

private enum RegistryRoute: Route {
    case a
    case b
}

@MainActor
private func noopMiddleware() -> AnyNavigationMiddleware<RegistryRoute> {
    AnyNavigationMiddleware(willExecute: { command, _ in .proceed(command) })
}

/// Reference-type collector: the registry under test is `@MainActor` so we don't
/// need `Mutex` for thread-safety, and `Mutex` is noncopyable which makes it
/// awkward to thread out of a helper.
@MainActor
private final class EventCollector {
    var events: [NavigationStoreTelemetryEvent<RegistryRoute>] = []
}

@MainActor
private func makeRegistryWithCollector() -> (
    registry: NavigationMiddlewareRegistry<RegistryRoute>,
    collector: EventCollector
) {
    let collector = EventCollector()
    let sink = NavigationStoreTelemetrySink<RegistryRoute>(
        logger: nil,
        recorder: { event in
            MainActor.assumeIsolated {
                collector.events.append(event)
            }
        }
    )
    let registry = NavigationMiddlewareRegistry<RegistryRoute>(
        registrations: [],
        telemetrySink: sink
    )
    return (registry, collector)
}

private func mutationActions(
    _ events: [NavigationStoreTelemetryEvent<RegistryRoute>]
) -> [NavigationStoreTelemetryEvent<RegistryRoute>.MiddlewareMutation] {
    events.compactMap { event in
        if case .middlewareMutation(let action, _, _) = event { return action }
        return nil
    }
}

private func mutationIndexes(
    _ events: [NavigationStoreTelemetryEvent<RegistryRoute>]
) -> [Int?] {
    events.compactMap { event in
        if case .middlewareMutation(_, _, let idx) = event { return idx }
        return nil
    }
}

// MARK: - Suite

@Suite("NavigationMiddlewareRegistry Tests")
struct NavigationMiddlewareRegistryTests {

    // MARK: - add

    @Test("add assigns handle, appends entry, emits added telemetry")
    @MainActor
    func addAssignsHandleAndEmitsAddedTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()

        let handle = registry.add(noopMiddleware(), debugName: "first")

        #expect(registry.metadata.map(\.handle) == [handle])
        #expect(mutationActions(collector.events) == [.added])
        #expect(mutationIndexes(collector.events) == [0])
        #expect(registry.metadata.first?.debugName == "first")
    }

    // MARK: - insert clamping

    @Test("insert clamps negative index to zero")
    @MainActor
    func insertClampsNegativeIndexToZero() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopMiddleware(), debugName: "first")

        let inserted = registry.insert(noopMiddleware(), at: -5, debugName: "head")

        #expect(registry.metadata.first?.handle == inserted)
        #expect(mutationActions(collector.events) == [.added, .inserted])
        #expect(mutationIndexes(collector.events) == [0, 0])
    }

    @Test("insert clamps out-of-bounds index to count")
    @MainActor
    func insertClampsOutOfBoundsToCount() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopMiddleware())
        _ = registry.add(noopMiddleware())

        let inserted = registry.insert(noopMiddleware(), at: 99, debugName: "tail")

        #expect(registry.metadata.last?.handle == inserted)
        #expect(mutationIndexes(collector.events).last == 2)
    }

    // MARK: - invalid handle no-ops

    @Test("remove with unknown handle returns nil and emits no telemetry")
    @MainActor
    func removeInvalidHandleReturnsNilAndEmitsNoTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopMiddleware())

        let stranger = NavigationMiddlewareHandle()
        let removed = registry.remove(stranger)

        #expect(removed == nil)
        #expect(registry.metadata.count == 1)
        #expect(mutationActions(collector.events) == [.added])
    }

    @Test("replace with unknown handle returns false and emits no telemetry")
    @MainActor
    func replaceInvalidHandleReturnsFalseAndEmitsNoTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopMiddleware())

        let stranger = NavigationMiddlewareHandle()
        let didReplace = registry.replace(stranger, with: noopMiddleware(), debugName: "ghost")

        #expect(didReplace == false)
        #expect(mutationActions(collector.events) == [.added])
    }

    @Test("move with unknown handle returns false and emits no telemetry")
    @MainActor
    func moveInvalidHandleReturnsFalseAndEmitsNoTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopMiddleware())

        let stranger = NavigationMiddlewareHandle()
        let didMove = registry.move(stranger, to: 0)

        #expect(didMove == false)
        #expect(mutationActions(collector.events) == [.added])
    }

    // MARK: - move clamping

    @Test("move to negative index clamps to zero")
    @MainActor
    func moveToNegativeIndexClampsToZero() {
        let (registry, _) = makeRegistryWithCollector()
        let first = registry.add(noopMiddleware(), debugName: "first")
        let second = registry.add(noopMiddleware(), debugName: "second")
        let third = registry.add(noopMiddleware(), debugName: "third")

        #expect(registry.move(third, to: -42))
        #expect(registry.metadata.map(\.handle) == [third, first, second])
    }

    @Test("move to large index clamps to count minus one")
    @MainActor
    func moveToLargeIndexClampsToCountMinusOne() {
        let (registry, collector) = makeRegistryWithCollector()
        let first = registry.add(noopMiddleware())
        _ = registry.add(noopMiddleware())
        _ = registry.add(noopMiddleware())

        #expect(registry.move(first, to: 99))
        #expect(registry.metadata.last?.handle == first)
        #expect(mutationIndexes(collector.events).last == 2)
    }

    // MARK: - empty registry no-ops

    @Test("empty registry: remove/replace/move are safe no-ops")
    @MainActor
    func emptyRegistryMutationMethodsNoop() {
        let (registry, collector) = makeRegistryWithCollector()
        let stranger = NavigationMiddlewareHandle()

        #expect(registry.remove(stranger) == nil)
        #expect(registry.replace(stranger, with: noopMiddleware()) == false)
        #expect(registry.move(stranger, to: 0) == false)

        #expect(collector.events.isEmpty)
    }

    // MARK: - order preservation

    @Test("handles order preserved across move")
    @MainActor
    func handlesOrderPreservedAcrossMove() {
        let (registry, _) = makeRegistryWithCollector()
        let a = registry.add(noopMiddleware())
        let b = registry.add(noopMiddleware())
        let c = registry.add(noopMiddleware())

        #expect(registry.move(a, to: 2))
        #expect(registry.metadata.map(\.handle) == [b, c, a])
    }

    // MARK: - handle uniqueness

    @Test("handle uniqueness across sequence of mutations")
    @MainActor
    func handleUniquenessAcrossMutations() {
        let (registry, _) = makeRegistryWithCollector()
        var seen: Set<NavigationMiddlewareHandle> = []
        var handles: [NavigationMiddlewareHandle] = []
        for _ in 0..<8 {
            let handle = registry.add(noopMiddleware())
            #expect(!seen.contains(handle))
            seen.insert(handle)
            handles.append(handle)
        }
        _ = registry.insert(noopMiddleware(), at: 0)
        _ = registry.remove(handles[3])
        let registeredHandles = registry.metadata.map(\.handle)
        #expect(Set(registeredHandles).count == registeredHandles.count)
    }

    // MARK: - replace preserves handle

    @Test("replace preserves handle identity but updates debug name")
    @MainActor
    func replacePreservesHandleButUpdatesDebugName() {
        let (registry, _) = makeRegistryWithCollector()
        let handle = registry.add(noopMiddleware(), debugName: "before")

        #expect(registry.replace(handle, with: noopMiddleware(), debugName: "after"))

        #expect(registry.metadata.map(\.handle) == [handle])
        #expect(registry.metadata.first?.debugName == "after")
    }
}
