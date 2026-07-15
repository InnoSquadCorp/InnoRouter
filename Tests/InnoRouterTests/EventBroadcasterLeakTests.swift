// MARK: - EventBroadcasterLeakTests.swift
// InnoRouterTests - EventBroadcaster subscriber lifecycle smoke
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
@testable import InnoRouterCore

// MARK: - Local fixtures

private enum LeakSmokeEvent: Sendable, Equatable {
    case ping(Int)
}

@MainActor
private func makeBroadcaster() -> EventBroadcaster<LeakSmokeEvent> {
    EventBroadcaster<LeakSmokeEvent>()
}

// MARK: - Suite

@Suite("EventBroadcaster subscriber lifecycle smoke")
struct EventBroadcasterLeakTests {

    // The broadcaster's `onTermination` cleanup runs through a small
    // `Task { @MainActor in ... }` hop because the AsyncStream
    // continuation termination callback is nonisolated. Under high
    // subscribe / cancel churn that hop must still drain the
    // continuations dictionary back to zero — otherwise long-lived
    // stores would slowly leak per-subscriber state. These smokes
    // exercise the round-trip and assert eventual cleanup, capturing
    // the contract for future refactors of the cleanup path
    // (e.g. moving from Task-spawn to a synchronous main-actor
    // queue).

    @Test("Single subscribe + iterator cancel drains to zero subscribers")
    @MainActor
    func singleSubscribeAndCancelDrains() async throws {
        let broadcaster = makeBroadcaster()
        // Scope the stream + iterator inside an inner closure so both
        // are deallocated before the cleanup-drain check. Holding a
        // strong reference to the stream past the consume keeps the
        // continuation alive and would mask whether onTermination
        // ever fires.
        await withSubscribedConsume(broadcaster: broadcaster) {
            broadcaster.broadcast(.ping(1))
        }

        try await waitUntil(timeout: .seconds(1)) {
            broadcaster.subscriberCount == 0
        }
    }

    @Test("Cancelling a suspended for-await task drains the subscriber")
    @MainActor
    func cancellingConsumerTaskDrains() async throws {
        let broadcaster = makeBroadcaster()
        let stream = broadcaster.stream()
        #expect(broadcaster.subscriberCount == 1)

        let task = Task<Void, Never> { @MainActor in
            for await _ in stream {}
        }
        await Task.yield()

        task.cancel()
        await task.value

        try await waitUntil(timeout: .seconds(1)) {
            broadcaster.subscriberCount == 0
        }
    }

    @Test("100 subscribe + cancel cycles drain to zero subscribers")
    @MainActor
    func bulkSubscribeAndCancelDrains() async throws {
        let broadcaster = makeBroadcaster()
        let cycleCount = 100

        for _ in 0..<cycleCount {
            let stream = broadcaster.stream()
            let task = Task<Void, Never> { @MainActor in
                var iterator = stream.makeAsyncIterator()
                broadcaster.broadcast(.ping(1))
                _ = await iterator.next()
            }
            await task.value
        }

        try await waitUntil(timeout: .seconds(2)) {
            broadcaster.subscriberCount == 0
        }
    }

    @Test("Multiple concurrent subscribers each receive every broadcast")
    @MainActor
    func concurrentSubscribersAllReceive() async throws {
        let broadcaster = makeBroadcaster()
        let firstStream = broadcaster.stream()
        let secondStream = broadcaster.stream()
        let thirdStream = broadcaster.stream()
        #expect(broadcaster.subscriberCount == 3)

        broadcaster.broadcast(.ping(1))
        broadcaster.broadcast(.ping(2))

        var firstIterator = firstStream.makeAsyncIterator()
        var secondIterator = secondStream.makeAsyncIterator()
        var thirdIterator = thirdStream.makeAsyncIterator()

        let firstA = await firstIterator.next()
        let secondA = await secondIterator.next()
        let thirdA = await thirdIterator.next()
        #expect(firstA == .ping(1))
        #expect(secondA == .ping(1))
        #expect(thirdA == .ping(1))

        let firstB = await firstIterator.next()
        let secondB = await secondIterator.next()
        let thirdB = await thirdIterator.next()
        #expect(firstB == .ping(2))
        #expect(secondB == .ping(2))
        #expect(thirdB == .ping(2))
    }

    @Test("Deallocating broadcaster finishes active streams")
    @MainActor
    func deallocatingBroadcasterFinishesActiveStreams() async throws {
        var broadcaster: EventBroadcaster<LeakSmokeEvent>? = makeBroadcaster()
        let stream: AsyncStream<LeakSmokeEvent>
        do {
            let activeBroadcaster = try #require(broadcaster)
            stream = activeBroadcaster.stream()
            #expect(activeBroadcaster.subscriberCount == 1)
        }

        broadcaster = nil

        let result = await nextValue(from: stream, timeout: .seconds(1))
        switch result {
        case .completed(let event):
            #expect(event == nil)
        case .timedOut:
            Issue.record("Timed out waiting for broadcaster deallocation to finish the stream")
        }
    }
}

// MARK: - Helpers

private enum TimedNextValue<Value: Sendable>: Sendable {
    case completed(Value?)
    case timedOut
}

@MainActor
private func withSubscribedConsume(
    broadcaster: EventBroadcaster<LeakSmokeEvent>,
    drive: @MainActor () -> Void
) async {
    let stream = broadcaster.stream()
    var iterator = stream.makeAsyncIterator()
    drive()
    _ = await iterator.next()
    // Both `stream` and `iterator` go out of scope on return, releasing
    // the only references to the AsyncStream and triggering its
    // onTermination cleanup.
}

@MainActor
private func waitUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    _ predicate: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !predicate() {
        if ContinuousClock.now > deadline {
            Issue.record("waitUntil exceeded timeout while waiting on predicate")
            return
        }
        try await Task.sleep(for: interval)
    }
}

private func nextValue(
    from stream: AsyncStream<LeakSmokeEvent>,
    timeout: Duration
) async -> TimedNextValue<LeakSmokeEvent> {
    return await withTaskGroup(of: TimedNextValue<LeakSmokeEvent>.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await .completed(iterator.next())
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return .timedOut
        }

        let result = await group.next() ?? .timedOut
        group.cancelAll()
        return result
    }
}
