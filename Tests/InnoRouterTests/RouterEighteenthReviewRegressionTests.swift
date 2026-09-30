import Foundation
import Observation
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum EighteenthReviewRoute: String, Route, Codable {
    case saved
    case current
    case second
}

private final class EighteenthReviewBlockingStorage: RouterSnapshotStorage {
    private enum StorageError: Error {
        case loadTimedOut
    }

    let loads: AsyncStream<Void>
    let saves: AsyncStream<Data>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let saveContinuation: AsyncStream<Data>.Continuation
    private let loadBarrier = DispatchSemaphore(value: 0)
    private let storedData: Data?
    private let savedData = Mutex<[Data]>([])

    init(data: Data?) {
        storedData = data
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
        (saves, saveContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    deinit {
        loadBarrier.signal()
        loadContinuation.finish()
        saveContinuation.finish()
    }

    var saveCount: Int { savedData.withLock { $0.count } }

    func releaseLoad() {
        loadBarrier.signal()
    }

    func load() throws -> Data? {
        loadContinuation.yield()
        guard loadBarrier.wait(timeout: .now() + 5) == .success else {
            throw StorageError.loadTimedOut
        }
        return storedData
    }

    func save(_ data: Data) throws {
        savedData.withLock { $0.append(data) }
        saveContinuation.yield(data)
    }

    func remove() throws {}
}

private final class EighteenthReviewSleepSignals: Sendable {
    let started: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    let woke = DispatchSemaphore(value: 0)

    init() {
        (started, startContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        startContinuation.finish()
        woke.signal()
    }

    @concurrent
    func sleep(_ duration: Duration) async throws {
        startContinuation.yield()
        try await Task.sleep(for: duration)
        woke.signal()
    }
}

@MainActor
private final class EighteenthReviewExpiryState {
    weak var history: RouterHistory<EighteenthReviewRoute>?
    var didReset = false
    var wakeConfirmed = false
    let expirations: AsyncStream<Date>
    private let expirationContinuation: AsyncStream<Date>.Continuation

    init() {
        (expirations, expirationContinuation) = AsyncStream.makeStream(of: Date.self)
    }

    deinit {
        expirationContinuation.finish()
    }

    func waitForWake(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 3) == .success
    }

    func recordExpiration() {
        expirationContinuation.yield(Date())
    }
}

private enum EighteenthReviewAwaitError: Error {
    case timedOut
    case streamFinished
}

private func firstValue<Element: Sendable>(
    from stream: AsyncStream<Element>,
    timeout: Duration = .seconds(3)
) async throws -> Element {
    try await withThrowingTaskGroup(of: Element.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let value = await iterator.next() else {
                throw EighteenthReviewAwaitError.streamFinished
            }
            return value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw EighteenthReviewAwaitError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

@Suite("Eighteenth review lifecycle regressions", .timeLimit(.minutes(1)))
@MainActor
struct RouterEighteenthReviewRegressionTests {
    @Test("Activation reservation observes and protects navigation before restore completes")
    func activationReservationProtectsNewerNavigation() async throws {
        let codec = try RouterSnapshotCodec<EighteenthReviewRoute>(currentVersion: 1)
        let snapshot = try codec.encode(.rootStack(path: [.saved]))
        let storage = EighteenthReviewBlockingStorage(data: snapshot)
        let store = RouterStore<EighteenthReviewRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            storage.releaseLoad()
            driver.stop()
        }

        _ = try await firstValue(from: storage.loads)
        #expect(store.eventObservationCount == 1)
        #expect(driver.status == .loading)
        #expect(try await driver.activate() == .alreadyActive)

        _ = await store.perform(.push(.current))
        storage.releaseLoad()
        _ = try await activation.value

        #expect(store.state.root == .stack(path: [.current]))
        #expect(store.revision == 1)
        #expect(store.eventObservationCount == 1)
    }

    @Test("A stopped activation cannot mutate its replacement lifetime")
    func stoppedActivationCannotMutateReplacement() async throws {
        let codec = try RouterSnapshotCodec<EighteenthReviewRoute>(currentVersion: 1)
        let snapshot = try codec.encode(.rootStack(path: [.saved]))
        let storage = EighteenthReviewBlockingStorage(data: snapshot)
        let store = RouterStore<EighteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let oldActivation = Task { @MainActor in try await driver.activate() }
        defer {
            oldActivation.cancel()
            storage.releaseLoad()
            driver.stop()
        }

        _ = try await firstValue(from: storage.loads)
        driver.stop()
        #expect(store.eventObservationCount == 0)
        #expect(try await driver.activate() == .observationResumed)
        #expect(store.eventObservationCount == 1)

        storage.releaseLoad()
        await #expect(throws: CancellationError.self) {
            _ = try await oldActivation.value
        }
        #expect(store.state.root == .stack(path: []))
        #expect(store.eventObservationCount == 1)

        var saves = storage.saves.makeAsyncIterator()
        _ = await store.perform(.push(.current))
        let saved = try #require(await saves.next())
        #expect(try codec.decode(saved).root == .stack(path: [.current]))
        #expect(storage.saveCount == 1)
    }

    @Test("Stop between internal success and caller return cannot restore manual ownership")
    func stopBeforeCallerReturnInvalidatesManualClaim() async throws {
        let codec = try RouterSnapshotCodec<EighteenthReviewRoute>(currentVersion: 1)
        let storage = EighteenthReviewBlockingStorage(data: nil)
        let store = RouterStore<EighteenthReviewRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            storage.releaseLoad()
            driver.stop()
        }

        _ = try await firstValue(from: storage.loads)
        let (stops, stopContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { stopContinuation.finish() }
        withObservationTracking {
            _ = driver.status
        } onChange: {
            Task { @MainActor in
                driver.stop()
                stopContinuation.yield()
            }
        }

        storage.releaseLoad()
        await #expect(throws: CancellationError.self) {
            _ = try await activation.value
        }
        _ = try await firstValue(from: stops)
        #expect(store.eventObservationCount == 0)

        let attachmentID = UUID()
        #expect(try await driver.attach(attachmentID) == .observationResumed)
        driver.detach(attachmentID)
        #expect(driver.attachmentCount == 0)
        #expect(store.eventObservationCount == 0)
        #expect(driver.status == .inactive)
    }

    @Test("Concurrent manual activation retains the surviving owner")
    func concurrentManualActivationKeepsObservation() async throws {
        let codec = try RouterSnapshotCodec<EighteenthReviewRoute>(currentVersion: 1)
        let storage = EighteenthReviewBlockingStorage(data: nil)
        let store = RouterStore<EighteenthReviewRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let first = Task { @MainActor in try await driver.activate() }
        defer {
            first.cancel()
            storage.releaseLoad()
            driver.stop()
        }

        _ = try await firstValue(from: storage.loads)
        #expect(try await driver.activate() == .alreadyActive)
        first.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await first.value
        }
        #expect(store.eventObservationCount == 1)

        storage.releaseLoad()
        _ = await store.perform(.push(.current))
        #expect(store.eventObservationCount == 1)
        driver.stop()
        #expect(store.eventObservationCount == 0)
    }

    @Test("Cancellation before the restore worker starts leaves activation retryable")
    func preCancelledActivationCanRetry() async throws {
        let codec = try RouterSnapshotCodec<EighteenthReviewRoute>(currentVersion: 1)
        let storage = EighteenthReviewBlockingStorage(data: nil)
        let store = RouterStore<EighteenthReviewRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let cancelled = Task { @MainActor in
            await Task.yield()
            return try await driver.activate()
        }
        cancelled.cancel()
        defer {
            cancelled.cancel()
            storage.releaseLoad()
            driver.stop()
        }

        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(driver.status == .inactive)
        #expect(store.eventObservationCount == 0)

        let retry = Task { @MainActor in try await driver.activate() }
        _ = try await firstValue(from: storage.loads)
        #expect(driver.status == .loading)
        #expect(store.eventObservationCount == 1)
        storage.releaseLoad()
        #expect(try await retry.value == .noSnapshot)
        #expect(driver.status == .active)
    }

    @Test("Manual runtime sleep cancellation drains its continuation")
    func manualRuntimeSleepCancellationCleansUp() async throws {
        let sleeper = ManualRuntimeSleeper()
        let sleeping = Task { try await sleeper.sleep(for: .seconds(60)) }
        _ = try await firstValue(from: sleeper.registrations)

        sleeping.cancel()
        await #expect(throws: CancellationError.self) {
            try await sleeping.value
        }
        #expect(await sleeper.pendingCount == 0)
    }

    @Test(
        "A stale expiration cannot remove a newer deferred request",
        arguments: [true, false]
    )
    func staleExpirationCannotRemoveNewRequest(reuseID: Bool) async throws {
        let oldID = RouterDeferralID()
        let newID = reuseID ? oldID : RouterDeferralID()
        let signals = EighteenthReviewSleepSignals()
        let observed = EighteenthReviewExpiryState()
        var configuration = RouterStoreConfiguration<EighteenthReviewRoute>(
            policies: [.init(name: "approval") { transition in
                if transition.context.source == .history { return .deferRequest(oldID) }
                if transition.action == .push(.second) { return .deferRequest(newID) }
                return .allow
            }],
            deferrals: .init(timeToLive: .milliseconds(200)),
            onEvent: { event in
                if case .policyPrepared(_, _, .deferRequest) = event,
                   observed.history != nil,
                   !observed.didReset {
                    observed.didReset = true
                    observed.wakeConfirmed = observed.waitForWake(signals.woke)
                    observed.history?.reset(sessionKey: "replacement")
                }
                if case .rejected(_, _, _, .deferralExpired, _) = event {
                    observed.recordExpiration()
                }
            }
        )
        configuration.runtimeDependencies = .init(
            now: Date.init,
            sleep: { duration in try await signals.sleep(duration) },
            makeTransitionID: RouterTransitionID.init
        )
        let store = RouterStore<EighteenthReviewRoute>(configuration: configuration)
        let history = RouterHistory(store: store)
        observed.history = nil
        defer { history.stop() }

        _ = await store.perform(.push(.current))
        guard case .deferred = await history.goBack() else {
            Issue.record("Expected the history request to defer")
            return
        }
        _ = try await firstValue(from: signals.started)
        observed.history = history

        let outcome = await store.perform(.push(.second))
        guard case .deferred(_, _, _, let metadata) = outcome else {
            Issue.record("Expected the replacement request to defer")
            return
        }
        #expect(observed.wakeConfirmed)
        #expect(store.deferredTransitions.map(\.id) == [newID])
        #expect(store.deferralExpirationTasks.count == 1)

        let expiredAt = try await firstValue(from: observed.expirations)
        #expect(expiredAt.timeIntervalSince(metadata.createdAt) >= 0.1)
        #expect(store.deferredTransitions.isEmpty)
        #expect(store.deferralExpirationTasks.isEmpty)
        #expect(store.revision == 1)
    }
}
