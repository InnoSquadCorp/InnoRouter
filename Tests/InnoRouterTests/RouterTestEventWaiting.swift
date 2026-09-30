import Foundation
import Testing

/// Why a shared finite wait gave up.
///
/// A regression test must fail with one of these instead of spinning when the
/// event it waits for never arrives or its stream ends first.
enum RouterTestWaitFailure: Error, CustomStringConvertible {
    case streamFinished(expected: String, seen: [String])
    case timedOut(expected: String, seen: [String], timeout: Duration)
    case conditionNotMet(String, timeout: Duration)

    var description: String {
        switch self {
        case .streamFinished(let expected, let seen):
            return "event stream finished before \"\(expected)\" arrived; seen: \(seen)"
        case .timedOut(let expected, let seen, let timeout):
            return "waiting for \"\(expected)\" timed out after \(timeout); seen: \(seen)"
        case .conditionNotMet(let description, let timeout):
            return "\(description) did not hold within \(timeout)"
        }
    }
}

/// Waits for one named event and returns every event observed up to and
/// including it.
///
/// The wait ends in bounded time on all four outcomes: the expected event
/// arrives, the stream finishes, the timeout elapses, or the caller is
/// cancelled. A finished stream is a failure rather than a silent retry, so a
/// missing event cannot turn into a loop that never suspends.
@discardableResult
func waitForEvent(
    _ expected: String,
    from stream: AsyncStream<String>,
    timeout: Duration = .seconds(5)
) async throws -> [String] {
    try await withThrowingTaskGroup(of: [String].self) { group in
        group.addTask {
            var seen: [String] = []
            for await event in stream {
                seen.append(event)
                if event == expected {
                    return seen
                }
            }
            try Task.checkCancellation()
            throw RouterTestWaitFailure.streamFinished(expected: expected, seen: seen)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RouterTestWaitFailure.timedOut(
                expected: expected,
                seen: [],
                timeout: timeout
            )
        }
        let seen = try await group.next()!
        group.cancelAll()
        return seen
    }
}

/// Waits until a main-actor condition holds.
///
/// The wait is bounded by `timeout` and honours cancellation, so a condition
/// that never becomes true fails the test instead of parking it forever. It
/// establishes *when* a state was reached, never the ordering of work that
/// produced it.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw RouterTestWaitFailure.conditionNotMet(description, timeout: timeout)
        }
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// Returns the next element of a stream, failing finitely when the stream ends
/// first or the timeout elapses.
func firstElement<Element: Sendable>(
    from stream: AsyncStream<Element>,
    timeout: Duration = .seconds(5),
    what description: String
) async throws -> Element {
    try await withThrowingTaskGroup(of: Element.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let element = await iterator.next() else {
                try Task.checkCancellation()
                throw RouterTestWaitFailure.streamFinished(expected: description, seen: [])
            }
            return element
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RouterTestWaitFailure.timedOut(
                expected: description,
                seen: [],
                timeout: timeout
            )
        }
        let element = try await group.next()!
        group.cancelAll()
        return element
    }
}
