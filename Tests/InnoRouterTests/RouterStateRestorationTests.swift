import Foundation
import Synchronization
import Testing

import InnoRouter
import InnoRouterSwiftUI

private enum RestorableRoute: String, Route, Codable {
    case home
    case detail
}

enum RestorationEventBuffer: Sendable, CaseIterable {
    case newestZero
    case newestOne
    case oldestZero
    case oldestOne
    case defaultLimit
    case unbounded

    var policy: EventBufferingPolicy {
        switch self {
        case .newestZero: .bufferingNewest(0)
        case .newestOne: .bufferingNewest(1)
        case .oldestZero: .bufferingOldest(0)
        case .oldestOne: .bufferingOldest(1)
        case .defaultLimit: .default
        case .unbounded: .unbounded
        }
    }
}

private final class BlockingLoadStorage: RouterSnapshotStorage {
    private struct State {
        var hasStarted = false
    }

    private let state = Mutex(State())
    private let releaseLoad = DispatchSemaphore(value: 0)
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    var loadStarted: Bool {
        state.withLock { $0.hasStarted }
    }

    func unblockLoad() {
        releaseLoad.signal()
    }

    func load() throws -> Data? {
        state.withLock { $0.hasStarted = true }
        releaseLoad.wait()
        return data
    }

    func save(_ data: Data) throws {}
    func remove() throws {}
}

private final class TransientFailureStorage: RouterSnapshotStorage {
    enum Failure: Error { case unavailable }

    private let attempts = Mutex(0)
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    var loadAttempts: Int {
        attempts.withLock { $0 }
    }

    func load() throws -> Data? {
        let attempt = attempts.withLock {
            $0 += 1
            return $0
        }
        if attempt == 1 { throw Failure.unavailable }
        return data
    }

    func save(_ data: Data) throws {}
    func remove() throws {}
}

private final class BlockingFailureStorage: RouterSnapshotStorage {
    enum Failure: Error { case unavailable }

    let loads: AsyncStream<Void>
    let saves: AsyncStream<Data>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let saveContinuation: AsyncStream<Data>.Continuation
    private let releaseLoad = DispatchSemaphore(value: 0)

    init() {
        (loads, loadContinuation) = AsyncStream<Void>.makeStream()
        (saves, saveContinuation) = AsyncStream<Data>.makeStream()
    }

    func unblockLoad() {
        releaseLoad.signal()
    }

    func load() throws -> Data? {
        loadContinuation.yield(())
        releaseLoad.wait()
        throw Failure.unavailable
    }

    func save(_ data: Data) throws {
        saveContinuation.yield(data)
    }

    func remove() throws {}
}

private final class BlockingThenEmptyStorage: RouterSnapshotStorage {
    let loads: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let releaseFirstLoad = DispatchSemaphore(value: 0)
    private let attempts = Mutex(0)

    init() {
        (loads, continuation) = AsyncStream<Void>.makeStream()
    }

    func unblockFirstLoad() {
        releaseFirstLoad.signal()
    }

    func load() throws -> Data? {
        let attempt = attempts.withLock { $0 += 1; return $0 }
        if attempt == 1 {
            continuation.yield(())
            releaseFirstLoad.wait()
        }
        return nil
    }

    func save(_ data: Data) throws {}
    func remove() throws {}
}

private final class BlockingFirstSaveStorage: RouterSnapshotStorage {
    private struct State {
        var saveCount = 0
        var hasFirstStarted = false
        var hasFirstFinished = false
        var savedData: [Data] = []
    }

    private let state = Mutex(State())
    private let releaseFirstSave = DispatchSemaphore(value: 0)
    let firstSaveStarts: AsyncStream<Void>
    let firstSaveFinishes: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private let finishContinuation: AsyncStream<Void>.Continuation

    init() {
        (firstSaveStarts, startContinuation) = AsyncStream<Void>.makeStream()
        (firstSaveFinishes, finishContinuation) = AsyncStream<Void>.makeStream()
    }

    var saveCount: Int { state.withLock { $0.saveCount } }
    var firstSaveStarted: Bool { state.withLock { $0.hasFirstStarted } }
    var firstSaveFinished: Bool { state.withLock { $0.hasFirstFinished } }
    var lastData: Data? { state.withLock { $0.savedData.last } }

    func unblockFirstSave() {
        releaseFirstSave.signal()
    }

    func load() throws -> Data? { nil }

    func save(_ data: Data) throws {
        let count = state.withLock {
            $0.saveCount += 1
            $0.savedData.append(data)
            if $0.saveCount == 1 { $0.hasFirstStarted = true }
            return $0.saveCount
        }
        if count == 1 {
            startContinuation.yield()
            releaseFirstSave.wait()
            state.withLock { $0.hasFirstFinished = true }
            finishContinuation.yield()
        }
    }

    func remove() throws {}
}

private final class SignalingSaveStorage: RouterSnapshotStorage {
    let saves: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        saves = stream
        self.continuation = continuation
    }

    func load() throws -> Data? { nil }

    func save(_ data: Data) throws {
        continuation.yield(data)
    }

    func remove() throws {}
}

private final class RecordingSnapshotStorage: RouterSnapshotStorage {
    private struct State {
        var data: Data?
        var saveCount = 0
    }

    private let state = Mutex(State())

    var data: Data? { state.withLock { $0.data } }
    var saveCount: Int { state.withLock { $0.saveCount } }

    func load() throws -> Data? { state.withLock { $0.data } }

    func save(_ data: Data) throws {
        state.withLock {
            $0.data = data
            $0.saveCount += 1
        }
    }

    func remove() throws {
        state.withLock { $0.data = nil }
    }
}

@MainActor
private final class RestorationPolicyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isWaiting = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        if isWaiting { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

@Suite("Router restoration driver")
@MainActor
struct RouterStateRestorationTests {
    @Test("File storage and driver restore through the canonical pipeline")
    func fileRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Restoration-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("router.snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }

        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let firstStore = RouterStore<RestorableRoute>()
        let firstDriver = RouterRestorationDriver(
            store: firstStore,
            codec: codec,
            storage: RouterFileSnapshotStorage(fileURL: fileURL),
            saveDebounce: .zero
        )

        #expect(try await firstDriver.activate() == .noSnapshot)
        _ = await firstStore.perform(.pushMany([.home, .detail]))
        try await firstDriver.save()
        firstDriver.stop()

        let restoredStore = RouterStore<RestorableRoute>()
        let restoredDriver = RouterRestorationDriver(
            store: restoredStore,
            codec: codec,
            storage: RouterFileSnapshotStorage(fileURL: fileURL)
        )

        guard case .restored(let outcome) = try await restoredDriver.activate() else {
            Issue.record("Expected a stored snapshot")
            return
        }
        guard case .restored(let decodedState) = outcome.decoding else {
            Issue.record("Expected restored provenance")
            return
        }
        #expect(decodedState.root == .stack(path: [.home, .detail]))
        #expect(restoredStore.state == decodedState)
        #expect(restoredStore.revision == 1)
        #expect(restoredDriver.status == .active)
    }

    @Test("Removing storage does not mutate the live router")
    func removeSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InnoRouter-Restoration-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("router.snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }

        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let store = RouterStore<RestorableRoute>(initialPath: [.home])
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: RouterFileSnapshotStorage(fileURL: fileURL)
        )

        _ = try await driver.activate()
        try await driver.save()
        try await driver.removeSnapshot()

        #expect(store.state.root == .stack(path: [.home]))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Committed transitions are coalesced into automatic snapshot writes")
    func automaticSave() async throws {
        let sleeper = ManualRuntimeSleeper()
        var registrations = sleeper.registrations.makeAsyncIterator()
        let storage = SignalingSaveStorage()
        var saves = storage.saves.makeAsyncIterator()
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        var configuration = RouterStoreConfiguration<RestorableRoute>()
        configuration.runtimeDependencies = manualRuntimeDependencies(sleeper: sleeper)
        let store = RouterStore<RestorableRoute>(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .seconds(30)
        )

        _ = try await driver.activate()
        _ = await store.perform(.push(.detail))
        #expect(await registrations.next() == .seconds(30))
        await sleeper.resumeAll()

        let data = try #require(await saves.next())
        #expect(try codec.decode(data).root == .stack(path: [.detail]))
        driver.stop()
    }

    @Test(
        "Automatic persistence does not depend on the diagnostic event buffer policy",
        arguments: RestorationEventBuffer.allCases
    )
    func automaticSaveSurvivesEventBufferOverflow(
        buffer: RestorationEventBuffer
    ) async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = RecordingSnapshotStorage()
        var configuration = RouterStoreConfiguration<RestorableRoute>()
        configuration.eventBufferingPolicy = buffer.policy
        let store = RouterStore<RestorableRoute>(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )

        _ = try await driver.activate()
        _ = await store.perform(.push(.detail))
        for _ in 0..<1_100 {
            _ = await store.perform(.pushIfNeeded(.detail))
        }

        try await waitUntil { storage.saveCount == 1 }
        let data = try #require(storage.data)
        #expect(try codec.decode(data).root == .stack(path: [.detail]))
        driver.stop()
    }

    @Test("Releasing a driver tears down observation without another Store event")
    func deinitRemovesOwnedObservationWithoutEvent() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let store = RouterStore<RestorableRoute>()
        var drivers: [RouterRestorationDriver<RestorableRoute>] = []
        var releaseChecks: [@MainActor () -> Bool] = []
        for _ in 0..<20 {
            let driver = RouterRestorationDriver(
                store: store,
                codec: codec,
                storage: RecordingSnapshotStorage(),
                saveDebounce: .seconds(30)
            )
            releaseChecks.append { [weak driver] in driver == nil }
            _ = try await driver.activate()
            drivers.append(driver)
        }

        #expect(store.eventObservationCount == 20)
        drivers.removeAll()

        #expect(releaseChecks.allSatisfy { $0() })
        #expect(store.eventObservationCount == 0)
    }

    @Test("A slow initial load never overwrites a newer committed revision")
    func slowLoadConflict() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let persisted = try codec.encode(.rootStack(path: [.home]))
        let storage = BlockingLoadStorage(data: persisted)
        let store = RouterStore<RestorableRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .seconds(30)
        )
        let activation = Task { @MainActor in
            try await driver.activate()
        }

        try await waitUntil { storage.loadStarted }
        _ = await store.perform(.push(.detail))
        storage.unblockLoad()

        guard case .restored(let restoration) = try await activation.value,
              case .rejected(_, _, _, let reason) = restoration.transition else {
            Issue.record("Expected stale restoration to be rejected")
            return
        }
        #expect(reason == .staleState(expectedRevision: 0, actualRevision: 1))
        #expect(store.state.root == .stack(path: [.detail]))
        driver.stop()
    }

    @Test("Activation retries after a transient storage failure")
    func retryAfterFailure() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let data = try codec.encode(.rootStack(path: [.home]))
        let storage = TransientFailureStorage(data: data)
        let store = RouterStore<RestorableRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage
        )

        do {
            _ = try await driver.activate()
            Issue.record("Expected the first activation to fail")
        } catch TransientFailureStorage.Failure.unavailable {}

        guard case .restored = try await driver.activate() else {
            Issue.record("Expected the second activation to restore")
            return
        }
        #expect(storage.loadAttempts == 2)
        #expect(store.state.root == .stack(path: [.home]))
    }

    @Test("A reattached completed driver keeps lifecycle save eligibility")
    func reattachPreservesLifecycleSaveEligibility() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = RecordingSnapshotStorage()
        let store = RouterStore<RestorableRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .seconds(3_600)
        )
        let firstAttachment = UUID()
        let secondAttachment = UUID()
        defer {
            driver.detach(firstAttachment)
            driver.detach(secondAttachment)
            driver.stop()
        }

        #expect(try await driver.attach(firstAttachment) == .noSnapshot)
        _ = await store.perform(.push(.detail))
        driver.detach(firstAttachment)
        #expect(storage.saveCount == 0)

        #expect(try await driver.attach(secondAttachment) == .observationResumed)
        await driver.saveForSceneLifecycle(attachmentID: secondAttachment)
        #expect(storage.saveCount == 1)
        let saved = try #require(storage.data)
        #expect(try codec.decode(saved) == .rootStack(path: [.detail]))
    }

    @Test("A stale activation failure cannot stop a newer observation lifetime")
    func staleActivationFailurePreservesNewObservation() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingFailureStorage()
        var loads = storage.loads.makeAsyncIterator()
        var saves = storage.saves.makeAsyncIterator()
        let store = RouterStore<RestorableRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let firstActivation = Task { @MainActor in
            try await driver.activate()
        }
        _ = await loads.next()

        driver.stop()
        #expect(try await driver.activate() == .observationResumed)
        storage.unblockLoad()
        await #expect(throws: CancellationError.self) {
            _ = try await firstActivation.value
        }

        #expect(driver.status == .active)
        #expect(try await driver.activate() == .alreadyActive)
        _ = await store.perform(.push(.detail))
        let data = try #require(await saves.next())
        #expect(try codec.decode(data).root == .stack(path: [.detail]))
        driver.stop()
    }

    @Test("A stale successful load cannot restore over a newer lifetime")
    func staleActivationSuccessCannotRestore() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingLoadStorage(
            data: try codec.encode(.rootStack(path: [.home]))
        )
        let store = RouterStore<RestorableRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let firstActivation = Task { @MainActor in
            try await driver.activate()
        }
        try await waitUntil { storage.loadStarted }

        driver.stop()
        #expect(try await driver.activate() == .observationResumed)
        storage.unblockLoad()
        await #expect(throws: CancellationError.self) {
            _ = try await firstActivation.value
        }

        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(driver.status == .active)
        #expect(try await driver.activate() == .alreadyActive)
        driver.stop()
    }

    @Test("Stopping during restoration policy evaluation prevents a late commit")
    func stopDuringRestorationPolicyPreventsCommit() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingLoadStorage(
            data: try codec.encode(.rootStack(path: [.home]))
        )
        let gate = RestorationPolicyGate()
        let store = RouterStore<RestorableRoute>(configuration: .init(policies: [
            RouterPolicy(name: "restore-gate") { transition in
                guard transition.context.source == .restoration else { return .allow }
                await gate.wait()
                return .allow
            },
        ]))
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in
            try await driver.activate()
        }
        try await waitUntil { storage.loadStarted }
        storage.unblockLoad()
        await gate.waitUntilEntered()

        driver.stop()
        gate.release()

        await #expect(throws: CancellationError.self) {
            _ = try await activation.value
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(driver.status == .inactive)
    }

    @Test("Stopping restoration releases the execution lane before policy completion")
    func stopDuringRestorationPolicyReleasesExecutionLane() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingLoadStorage(
            data: try codec.encode(.rootStack(path: [.home]))
        )
        let gate = RestorationPolicyGate()
        let store = RouterStore<RestorableRoute>(configuration: .init(
            policies: [
                RouterPolicy(name: "restore-gate") { transition in
                    guard transition.context.source == .restoration else { return .allow }
                    await gate.wait()
                    return .allow
                },
            ],
            schedulingPolicy: .rejectWhileBusy
        ))
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in
            try await driver.activate()
        }
        try await waitUntil { storage.loadStarted }
        storage.unblockLoad()
        await gate.waitUntilEntered()

        driver.stop()
        await #expect(throws: CancellationError.self) {
            _ = try await activation.value
        }
        #expect(driver.status == .inactive)

        guard case .applied = await store.perform(.push(.detail)) else {
            Issue.record("Expected stop to release the restoration execution lane")
            gate.release()
            return
        }
        #expect(store.state == .rootStack(path: [.detail]))
        #expect(store.revision == 1)

        gate.release()
        #expect(store.state == .rootStack(path: [.detail]))
        #expect(store.revision == 1)
    }

    @Test("Stopping restoration preserves a serialized request queued behind it")
    func stopDuringRestorationPreservesSerializedRequest() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingLoadStorage(
            data: try codec.encode(.rootStack(path: [.home]))
        )
        let gate = RestorationPolicyGate()
        let store = RouterStore<RestorableRoute>(configuration: .init(policies: [
            RouterPolicy(name: "restore-gate") { transition in
                guard transition.context.source == .restoration else { return .allow }
                await gate.wait()
                return .allow
            },
        ]))
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in try await driver.activate() }
        try await waitUntil { storage.loadStarted }
        storage.unblockLoad()
        await gate.waitUntilEntered()

        driver.stop()
        let navigation = Task { @MainActor in await store.perform(.push(.detail)) }
        await #expect(throws: CancellationError.self) {
            _ = try await activation.value
        }
        guard case .applied = await navigation.value else {
            Issue.record("Expected the serialized navigation to survive restoration cancellation")
            gate.release()
            return
        }
        #expect(store.state == .rootStack(path: [.detail]))
        #expect(store.revision == 1)
        gate.release()
    }

    @Test("Cancelling activation releases restoration policy execution")
    func activationCancellationReleasesExecutionLane() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingLoadStorage(
            data: try codec.encode(.rootStack(path: [.home]))
        )
        let gate = RestorationPolicyGate()
        let store = RouterStore<RestorableRoute>(configuration: .init(
            policies: [
                RouterPolicy(name: "restore-gate") { transition in
                    guard transition.context.source == .restoration else { return .allow }
                    await gate.wait()
                    return .allow
                },
            ],
            schedulingPolicy: .rejectWhileBusy
        ))
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in try await driver.activate() }
        try await waitUntil { storage.loadStarted }
        storage.unblockLoad()
        await gate.waitUntilEntered()

        activation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await activation.value
        }
        guard case .applied = await store.perform(.push(.detail)) else {
            Issue.record("Expected caller cancellation to release the restoration lane")
            gate.release()
            return
        }
        #expect(store.state == .rootStack(path: [.detail]))
        #expect(store.revision == 1)
        #expect(driver.status == .inactive)
        gate.release()
    }

    @Test("Cancelling activation stops its observation and permits a clean retry")
    func activationCancellationCleansUpOwnedObservation() async throws {
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingThenEmptyStorage()
        var loads = storage.loads.makeAsyncIterator()
        let store = RouterStore<RestorableRoute>()
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activation = Task { @MainActor in
            try await driver.activate()
        }
        _ = await loads.next()

        activation.cancel()
        storage.unblockFirstLoad()

        await #expect(throws: CancellationError.self) {
            _ = try await activation.value
        }
        #expect(driver.status == .inactive)
        do {
            let retry = try await driver.activate()
            #expect(retry == .noSnapshot)
        } catch {
            Issue.record("Expected activation retry, got \(error)")
        }
        driver.stop()
    }

    @Test("An older save cannot discard the newer debounce handle or final snapshot")
    func saveHandleOwnership() async throws {
        let sleeper = ManualRuntimeSleeper()
        var registrations = sleeper.registrations.makeAsyncIterator()
        let codec = try RouterSnapshotCodec<RestorableRoute>(currentVersion: 1)
        let storage = BlockingFirstSaveStorage()
        var saveStarts = storage.firstSaveStarts.makeAsyncIterator()
        var saveFinishes = storage.firstSaveFinishes.makeAsyncIterator()
        var configuration = RouterStoreConfiguration<RestorableRoute>()
        configuration.runtimeDependencies = manualRuntimeDependencies(sleeper: sleeper)
        let store = RouterStore<RestorableRoute>(configuration: configuration)
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .milliseconds(500)
        )

        _ = try await driver.activate()
        _ = await store.perform(.push(.home))
        #expect(await registrations.next() == .milliseconds(500))
        await sleeper.resumeAll()
        _ = await saveStarts.next()

        _ = await store.perform(.push(.detail))
        #expect(await registrations.next() == .milliseconds(500))
        storage.unblockFirstSave()
        _ = await saveFinishes.next()
        await sleeper.resumeAll()

        try await waitUntil { storage.saveCount == 2 }
        let data = try #require(storage.lastData)
        #expect(try codec.decode(data).root == .stack(path: [.home, .detail]))
        driver.stop()
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for a controlled storage operation")
    }
}
