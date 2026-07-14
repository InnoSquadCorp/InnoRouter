// MARK: - ModalMiddlewareRegistryTests.swift
// InnoRouterTests - ModalMiddlewareRegistry invariants and edge cases
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import InnoRouterCore
@testable import InnoRouterSwiftUI

// MARK: - Local fixtures

private enum ModalRegistryRoute: Route {
    case a
    case b
}

@MainActor
private func noopModalMiddleware() -> AnyModalMiddleware<ModalRegistryRoute> {
    AnyModalMiddleware(willExecute: { command, _, _ in .proceed(command) })
}

@MainActor
private final class ModalEventCollector {
    var events: [ModalStoreTelemetryEvent<ModalRegistryRoute>] = []
}

@MainActor
private func makeRegistryWithCollector() -> (
    registry: ModalMiddlewareRegistry<ModalRegistryRoute>,
    collector: ModalEventCollector
) {
    let collector = ModalEventCollector()
    let sink = ModalStoreTelemetrySink<ModalRegistryRoute>(
        logger: nil,
        recorder: { event in
            MainActor.assumeIsolated {
                collector.events.append(event)
            }
        }
    )
    let registry = ModalMiddlewareRegistry<ModalRegistryRoute>(
        registrations: [],
        telemetrySink: sink
    )
    return (registry, collector)
}

private func mutationActions(
    _ events: [ModalStoreTelemetryEvent<ModalRegistryRoute>]
) -> [ModalStoreTelemetryEvent<ModalRegistryRoute>.MiddlewareMutation] {
    events.compactMap { event in
        if case .middlewareMutation(let action, _, _) = event { return action }
        return nil
    }
}

private func mutationIndexes(
    _ events: [ModalStoreTelemetryEvent<ModalRegistryRoute>]
) -> [Int?] {
    events.compactMap { event in
        if case .middlewareMutation(_, _, let idx) = event { return idx }
        return nil
    }
}

// MARK: - Suite

@Suite("ModalMiddlewareRegistry Tests")
struct ModalMiddlewareRegistryTests {

    @Test("add assigns handle, appends entry, emits added telemetry")
    @MainActor
    func addAssignsHandleAndEmitsAddedTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()
        let handle = registry.add(noopModalMiddleware(), debugName: "first")

        #expect(registry.metadata.map(\.handle) == [handle])
        #expect(mutationActions(collector.events) == [.added])
        #expect(mutationIndexes(collector.events) == [0])
        #expect(registry.metadata.first?.debugName == "first")
    }

    @Test("insert clamps negative index to zero")
    @MainActor
    func insertClampsNegativeIndexToZero() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopModalMiddleware(), debugName: "first")

        let inserted = registry.insert(noopModalMiddleware(), at: -5, debugName: "head")

        #expect(registry.metadata.first?.handle == inserted)
        #expect(mutationActions(collector.events) == [.added, .inserted])
        #expect(mutationIndexes(collector.events) == [0, 0])
    }

    @Test("insert clamps out-of-bounds index to count")
    @MainActor
    func insertClampsOutOfBoundsToCount() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopModalMiddleware())
        _ = registry.add(noopModalMiddleware())

        let inserted = registry.insert(noopModalMiddleware(), at: 99, debugName: "tail")

        #expect(registry.metadata.last?.handle == inserted)
        #expect(mutationIndexes(collector.events).last == 2)
    }

    @Test("remove with unknown handle returns nil and emits no telemetry")
    @MainActor
    func removeInvalidHandleReturnsNilAndEmitsNoTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopModalMiddleware())

        let stranger = ModalMiddlewareHandle()
        let removed = registry.remove(stranger)

        #expect(removed == nil)
        #expect(registry.metadata.count == 1)
        #expect(mutationActions(collector.events) == [.added])
    }

    @Test("replace with unknown handle returns false and emits no telemetry")
    @MainActor
    func replaceInvalidHandleReturnsFalseAndEmitsNoTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopModalMiddleware())

        let stranger = ModalMiddlewareHandle()
        let didReplace = registry.replace(stranger, with: noopModalMiddleware(), debugName: "ghost")

        #expect(didReplace == false)
        #expect(mutationActions(collector.events) == [.added])
    }

    @Test("move with unknown handle returns false and emits no telemetry")
    @MainActor
    func moveInvalidHandleReturnsFalseAndEmitsNoTelemetry() {
        let (registry, collector) = makeRegistryWithCollector()
        _ = registry.add(noopModalMiddleware())

        let stranger = ModalMiddlewareHandle()
        let didMove = registry.move(stranger, to: 0)

        #expect(didMove == false)
        #expect(mutationActions(collector.events) == [.added])
    }

    @Test("move to negative index clamps to zero")
    @MainActor
    func moveToNegativeIndexClampsToZero() {
        let (registry, _) = makeRegistryWithCollector()
        let first = registry.add(noopModalMiddleware(), debugName: "first")
        let second = registry.add(noopModalMiddleware(), debugName: "second")
        let third = registry.add(noopModalMiddleware(), debugName: "third")

        #expect(registry.move(third, to: -42))
        #expect(registry.metadata.map(\.handle) == [third, first, second])
    }

    @Test("move to large index clamps to count minus one")
    @MainActor
    func moveToLargeIndexClampsToCountMinusOne() {
        let (registry, collector) = makeRegistryWithCollector()
        let first = registry.add(noopModalMiddleware())
        _ = registry.add(noopModalMiddleware())
        _ = registry.add(noopModalMiddleware())

        #expect(registry.move(first, to: 99))
        #expect(registry.metadata.last?.handle == first)
        #expect(mutationIndexes(collector.events).last == 2)
    }

    @Test("empty registry: remove/replace/move are safe no-ops")
    @MainActor
    func emptyRegistryMutationMethodsNoop() {
        let (registry, collector) = makeRegistryWithCollector()
        let stranger = ModalMiddlewareHandle()

        #expect(registry.remove(stranger) == nil)
        #expect(registry.replace(stranger, with: noopModalMiddleware()) == false)
        #expect(registry.move(stranger, to: 0) == false)

        #expect(collector.events.isEmpty)
    }

    @Test("handles order preserved across move")
    @MainActor
    func handlesOrderPreservedAcrossMove() {
        let (registry, _) = makeRegistryWithCollector()
        let a = registry.add(noopModalMiddleware())
        let b = registry.add(noopModalMiddleware())
        let c = registry.add(noopModalMiddleware())

        #expect(registry.move(a, to: 2))
        #expect(registry.metadata.map(\.handle) == [b, c, a])
    }

    @Test("handle uniqueness across sequence of mutations")
    @MainActor
    func handleUniquenessAcrossMutations() {
        let (registry, _) = makeRegistryWithCollector()
        var seen: Set<ModalMiddlewareHandle> = []
        var handles: [ModalMiddlewareHandle] = []
        for _ in 0..<8 {
            let handle = registry.add(noopModalMiddleware())
            #expect(!seen.contains(handle))
            seen.insert(handle)
            handles.append(handle)
        }
        _ = registry.insert(noopModalMiddleware(), at: 0)
        _ = registry.remove(handles[3])
        let registeredHandles = registry.metadata.map(\.handle)
        #expect(Set(registeredHandles).count == registeredHandles.count)
    }

    @Test("replace preserves handle identity but updates debug name")
    @MainActor
    func replacePreservesHandleButUpdatesDebugName() {
        let (registry, _) = makeRegistryWithCollector()
        let handle = registry.add(noopModalMiddleware(), debugName: "before")

        #expect(registry.replace(handle, with: noopModalMiddleware(), debugName: "after"))

        #expect(registry.metadata.map(\.handle) == [handle])
        #expect(registry.metadata.first?.debugName == "after")
    }
}
