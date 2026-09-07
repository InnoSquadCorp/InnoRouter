import Foundation

import InnoRouterCore
import InnoRouterSwiftUI

actor ManualRuntimeSleeper {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
    }

    let registrations: AsyncStream<Duration>
    private let registrationContinuation: AsyncStream<Duration>.Continuation
    private var waiters: [UUID: Waiter] = [:]

    init() {
        let (stream, continuation) = AsyncStream<Duration>.makeStream()
        registrations = stream
        registrationContinuation = continuation
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        await withCheckedContinuation { continuation in
            waiters[id] = Waiter(continuation: continuation)
            registrationContinuation.yield(duration)
        }
    }

    func resumeAll() {
        let continuations = waiters.values.map(\.continuation)
        waiters.removeAll(keepingCapacity: true)
        for continuation in continuations {
            continuation.resume()
        }
    }
}

func manualRuntimeDependencies(
    sleeper: ManualRuntimeSleeper,
    now: Date = Date(timeIntervalSince1970: 1_000),
    transitionID: RouterTransitionID = RouterTransitionID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    )
) -> RouterRuntimeDependencies {
    RouterRuntimeDependencies(
        now: { now },
        sleep: { duration in
            try await sleeper.sleep(for: duration)
        },
        makeTransitionID: { transitionID }
    )
}
