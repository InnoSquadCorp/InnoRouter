import Foundation
import Observation
import Synchronization
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum NineteenthReviewRoute: String, Route, Codable {
    case saved
    case current
}

/// A route whose `broken` case cannot be encoded, so a save fails inside the
/// codec before it ever reaches storage.
private enum NineteenthReviewFragileRoute: Route, Codable {
    case saved
    case broken

    private enum Failure: Error {
        case unencodable
    }

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        self = kind == "broken" ? .broken : .saved
    }

    func encode(to encoder: any Encoder) throws {
        guard case .saved = self else { throw Failure.unencodable }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("saved", forKey: .kind)
    }
}

/// What a concurrent save does while the initial restore is still pending.
enum NineteenthReviewSaveScenario: String, CaseIterable, Sendable, CustomStringConvertible {
    case none
    case succeeding
    case failing

    var description: String { rawValue }
}

private struct NineteenthReviewStorageLog: Sendable {
    var file: Data?
    var operations: [String] = []
    var loadCount = 0
}

/// Records durable operations in the order storage actually performs them and
/// holds `load` open so later commands have to queue behind it.
private final class NineteenthReviewRecordingStorage: RouterSnapshotStorage {
    private enum StorageError: Error {
        case loadTimedOut
    }

    let loads: AsyncStream<Void>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let loadBarrier = DispatchSemaphore(value: 0)
    private let blocksLoads = Mutex<Bool>(true)
    private let log: Mutex<NineteenthReviewStorageLog>

    init(data: Data?) {
        log = Mutex(NineteenthReviewStorageLog(file: data))
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        loadBarrier.signal()
        loadContinuation.finish()
    }

    var state: NineteenthReviewStorageLog { log.withLock { $0 } }

    /// Lets one blocked load finish.
    func releaseLoad() {
        loadBarrier.signal()
    }

    /// Lets the current and every later load finish without blocking.
    func unblockLoads() {
        blocksLoads.withLock { $0 = false }
        loadBarrier.signal()
    }

    func load() throws -> Data? {
        log.withLock { $0.loadCount += 1 }
        loadContinuation.yield()
        if blocksLoads.withLock({ $0 }) {
            guard loadBarrier.wait(timeout: .now() + 5) == .success else {
                throw StorageError.loadTimedOut
            }
        }
        return log.withLock { $0.file }
    }

    func save(_ data: Data) throws {
        log.withLock {
            $0.file = data
            $0.operations.append("save")
        }
    }

    func remove() throws {
        log.withLock {
            $0.file = nil
            $0.operations.append("remove")
        }
    }
}

@Suite("Nineteenth review persistence regressions", .timeLimit(.minutes(1)))
@MainActor
struct RouterNineteenthReviewRegressionTests {
    /// R6R19-F01 — the driver accepts the save first and the remove second, so
    /// the remove must win no matter which command reaches storage first.
    @Test("An accepted remove is not undone by an older save")
    func acceptedRemoveIsNotUndoneByOlderSave() async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewRoute>(currentVersion: 1)
        let stored = try codec.encode(.rootStack(path: [.saved]))
        let storage = NineteenthReviewRecordingStorage(data: stored)
        let store = RouterStore<NineteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            storage.unblockLoads()
            driver.stop()
        }

        // The blocked load occupies storage, so both durable commands below
        // queue instead of running as they are submitted.
        _ = try await firstElement(from: storage.loads, what: "blocking load")

        let save = Task(priority: .low) { @MainActor in try await driver.save() }
        try await waitUntil("the save reaches storage") { driver.status == .saving }

        let remove = Task(priority: .high) { @MainActor in try await driver.removeSnapshot() }
        // Hand the main actor to the higher-priority remove so it reaches its
        // own storage call. Ordering is decided by submission, not by this.
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        storage.releaseLoad()
        _ = try? await activation.value
        _ = try? await save.value
        try await remove.value

        let state = storage.state
        #expect(
            state.file == nil,
            "durable state survived the accepted remove; storage order: \(state.operations)"
        )
    }

    /// R6R19-F03 — an unfinished initial restore stays retryable regardless of
    /// what a concurrent save did to the displayed status. The `none` case is
    /// the control: with no save at all the retry already works today.
    @Test(
        "An unfinished initial restore stays retryable after a save",
        arguments: NineteenthReviewSaveScenario.allCases
    )
    func initialRestoreStaysRetryableAfterSave(
        scenario: NineteenthReviewSaveScenario
    ) async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewFragileRoute>(currentVersion: 1)
        let stored = try codec.encode(.rootStack(path: [.saved]))
        let storage = NineteenthReviewRecordingStorage(data: stored)
        let store = RouterStore<NineteenthReviewFragileRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            storage.unblockLoads()
            driver.stop()
        }

        _ = try await firstElement(from: storage.loads, what: "blocking load")
        if scenario == .failing {
            _ = await store.perform(.push(.broken))
        }
        var save: Task<Void, any Error>?
        switch scenario {
        case .none:
            break
        case .succeeding:
            save = Task { @MainActor in try await driver.save() }
            try await waitUntil("the save reaches storage") { driver.status == .saving }
        case .failing:
            save = Task { @MainActor in try await driver.save() }
            try await waitUntil("the save fails") {
                if case .failed = driver.status { return true }
                return false
            }
        }

        // The only owner goes away before the initial restore ever finished.
        activation.cancel()
        _ = try? await activation.value
        storage.unblockLoads()
        _ = try? await save?.value

        let retry = try await driver.activate()
        let state = storage.state
        #expect(
            state.loadCount == 2,
            "the retry did not read storage again (activation: \(retry))"
        )
        if case .observationResumed = retry {
            Issue.record("the retry resumed observation instead of restoring")
        }
    }
}

/// Delegates to real file storage while holding `load` open, so command order
/// can be observed against bytes that actually reach disk.
private final class NineteenthReviewBlockingFileStorage: RouterSnapshotStorage {
    private enum StorageError: Error {
        case loadTimedOut
    }

    let loads: AsyncStream<Void>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let loadBarrier = DispatchSemaphore(value: 0)
    private let blocksLoads = Mutex<Bool>(true)
    private let wrapped: RouterFileSnapshotStorage

    init(fileURL: URL) {
        wrapped = RouterFileSnapshotStorage(fileURL: fileURL)
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        loadBarrier.signal()
        loadContinuation.finish()
    }

    func releaseLoad() {
        loadBarrier.signal()
    }

    func unblockLoads() {
        blocksLoads.withLock { $0 = false }
        loadBarrier.signal()
    }

    func load() throws -> Data? {
        loadContinuation.yield()
        if blocksLoads.withLock({ $0 }) {
            guard loadBarrier.wait(timeout: .now() + 5) == .success else {
                throw StorageError.loadTimedOut
            }
        }
        return try wrapped.load()
    }

    func save(_ data: Data) throws {
        try wrapped.save(data)
    }

    func remove() throws {
        try wrapped.remove()
    }
}

@Suite("Nineteenth review durable ordering", .timeLimit(.minutes(1)))
@MainActor
struct RouterNineteenthReviewDurableOrderingTests {
    /// AC-005 and AC-006 — the removal must win on disk, and a save accepted
    /// after it must still be written.
    @Test("A removal wins on disk and a later save is still accepted")
    func removalWinsOnDiskAndLaterSaveIsAccepted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("innorouter-r19-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("snapshot.json")

        let codec = try RouterSnapshotCodec<NineteenthReviewRoute>(currentVersion: 1)
        let initialState = RouterState<NineteenthReviewRoute>.rootStack(path: [.saved])
        try codec.encode(initialState).write(to: fileURL)

        let storage = NineteenthReviewBlockingFileStorage(fileURL: fileURL)
        // A changed initial restore would legitimately schedule a new automatic
        // save after removal. Keep that independent command out of this test
        // of saves accepted before removal and an explicit save accepted later.
        let store = RouterStore(initialState: initialState)
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            storage.unblockLoads()
            driver.stop()
        }

        _ = try await firstElement(from: storage.loads, what: "blocking load")
        let save = Task(priority: .low) { @MainActor in try await driver.save() }
        try await waitUntil("the save reaches storage") { driver.status == .saving }
        let (reservations, reservationContinuation) = AsyncStream.makeStream(of: RouterDurabilityReservation.self)
        defer { reservationContinuation.finish() }
        try await RouterDurabilityTestSupport.withReservationObserver({ reservation in
            reservationContinuation.yield(reservation)
        }) {
            let remove = Task(priority: .high) { @MainActor in try await driver.removeSnapshot() }
            defer { remove.cancel() }
            #expect(try await firstElement(
                from: reservations,
                what: "on-disk snapshot removal reservation"
            ) == .init(ticket: 1, command: .remove))
            storage.releaseLoad()
            _ = try await activation.value
            try await save.value
            try await remove.value
        }
        #expect(store.revision == 0)

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)

        let emptyStore = RouterStore<NineteenthReviewRoute>()
        let emptyDriver = RouterRestorationDriver(
            store: emptyStore,
            codec: codec,
            storage: RouterFileSnapshotStorage(fileURL: fileURL),
            saveDebounce: .zero
        )
        defer { emptyDriver.stop() }
        guard case .noSnapshot = try await emptyDriver.activate() else {
            Issue.record("a fresh driver restored a snapshot that was removed")
            return
        }

        // A save accepted after the removal is ordinary work, not stale work.
        _ = await store.perform(.push(.current))
        try await driver.save()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let reopenedStore = RouterStore<NineteenthReviewRoute>()
        let reopenedDriver = RouterRestorationDriver(
            store: reopenedStore,
            codec: codec,
            storage: RouterFileSnapshotStorage(fileURL: fileURL),
            saveDebounce: .zero
        )
        defer { reopenedDriver.stop() }
        guard case .restored = try await reopenedDriver.activate() else {
            Issue.record("the save accepted after the removal was not restorable")
            return
        }
        #expect(reopenedStore.state.root == store.state.root)
    }

    /// AC-008 and NFR-003 — ordering is per driver, so one driver blocked in
    /// storage must not hold up an unrelated driver.
    @Test("A driver blocked in storage does not stall another driver")
    func blockedDriverDoesNotStallAnotherDriver() async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewRoute>(currentVersion: 1)
        let blockedStorage = NineteenthReviewRecordingStorage(data: nil)
        let blockedStore = RouterStore<NineteenthReviewRoute>()
        let blockedDriver = RouterRestorationDriver(
            store: blockedStore,
            codec: codec,
            storage: blockedStorage,
            saveDebounce: .zero
        )
        let blockedActivation = Task { @MainActor in try await blockedDriver.activate() }
        defer {
            blockedActivation.cancel()
            blockedStorage.unblockLoads()
            blockedDriver.stop()
        }
        _ = try await firstElement(from: blockedStorage.loads, what: "blocking load")

        let otherStorage = NineteenthReviewRecordingStorage(data: nil)
        otherStorage.unblockLoads()
        let otherStore = RouterStore<NineteenthReviewRoute>()
        let otherDriver = RouterRestorationDriver(
            store: otherStore,
            codec: codec,
            storage: otherStorage,
            saveDebounce: .zero
        )
        defer { otherDriver.stop() }
        _ = try await otherDriver.activate()
        _ = await otherStore.perform(.push(.current))
        try await otherDriver.save()

        #expect(otherStorage.state.operations == ["save"])
        #expect(blockedStorage.state.operations.isEmpty)
    }
}

/// Real pending-link file storage with a held-open load.
private final class NineteenthReviewBlockingPendingLinkStorage: RouterPendingLinkStorage {
    private enum StorageError: Error {
        case loadTimedOut
    }

    let loads: AsyncStream<Void>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let loadBarrier = DispatchSemaphore(value: 0)
    private let blocksLoads = Mutex<Bool>(true)
    private let wrapped: RouterFilePendingLinkStorage

    init(fileURL: URL) {
        wrapped = RouterFilePendingLinkStorage(fileURL: fileURL)
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        loadBarrier.signal()
        loadContinuation.finish()
    }

    func releaseLoad() {
        loadBarrier.signal()
    }

    func unblockLoads() {
        blocksLoads.withLock { $0 = false }
        loadBarrier.signal()
    }

    func load() throws -> Data? {
        loadContinuation.yield()
        if blocksLoads.withLock({ $0 }) {
            guard loadBarrier.wait(timeout: .now() + 5) == .success else {
                throw StorageError.loadTimedOut
            }
        }
        return try wrapped.load()
    }

    func save(_ data: Data) throws {
        try wrapped.save(data)
    }

    func remove() throws {
        try wrapped.remove()
    }
}

/// Fails one chosen operation so later commands can be observed.
private final class NineteenthReviewFailingStorage: RouterSnapshotStorage {
    enum Mode: Sendable {
        case failsSave
        case failsRemove
    }

    private enum StorageError: Error {
        case injected
    }

    private let mode: Mode
    private let log = Mutex(NineteenthReviewStorageLog())

    init(mode: Mode) {
        self.mode = mode
    }

    var state: NineteenthReviewStorageLog { log.withLock { $0 } }

    func load() throws -> Data? { log.withLock { $0.file } }

    func save(_ data: Data) throws {
        if case .failsSave = mode { throw StorageError.injected }
        log.withLock {
            $0.file = data
            $0.operations.append("save")
        }
    }

    func remove() throws {
        if case .failsRemove = mode { throw StorageError.injected }
        log.withLock {
            $0.file = nil
            $0.operations.append("remove")
        }
    }
}

@Suite("Nineteenth review durable ordering matrix", .timeLimit(.minutes(1)))
@MainActor
struct RouterNineteenthReviewDurableMatrixTests {
    /// AC-005 — the same ordering guarantee on real pending-link storage.
    @Test("A cancelled pending link is not rewritten by an older submit")
    func cancelledPendingLinkIsNotRewrittenByOlderSubmit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("innorouter-r19-pending-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("pending-link.json")

        let storage = NineteenthReviewBlockingPendingLinkStorage(fileURL: fileURL)
        let slot = RouterPendingLinkSlot<NineteenthReviewRoute>()
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage)
        defer { storage.unblockLoads() }

        let restore = Task { @MainActor in try await driver.restore() }
        _ = try await firstElement(from: storage.loads, what: "blocking load")

        let link = PendingRouterLink<NineteenthReviewRoute>(
            url: try #require(URL(string: "innorouter://app/pending")),
            gatedRoute: .saved,
            plan: RouterPlan(state: .rootStack(path: [.saved]))
        )
        let (reservations, reservationContinuation) = AsyncStream.makeStream(
            of: RouterDurabilityReservation.self
        )
        defer { reservationContinuation.finish() }
        try await RouterDurabilityTestSupport.withReservationObserver({ reservation in
            reservationContinuation.yield(reservation)
        }) {
            let submit = Task(priority: .low) { @MainActor in try await driver.submit(link) }
            defer { submit.cancel() }
            let saveReservation = try await firstElement(
                from: reservations,
                what: "pending-link save reservation"
            )
            #expect(saveReservation == .init(ticket: 0, command: .save))

            let cancel = Task(priority: .high) { @MainActor in try await driver.cancel() }
            defer { cancel.cancel() }
            let removeReservation = try await firstElement(
                from: reservations,
                what: "pending-link remove reservation"
            )
            #expect(removeReservation == .init(ticket: 1, command: .remove))

            storage.releaseLoad()
            await #expect(throws: CancellationError.self) {
                _ = try await restore.value
            }
            await #expect(throws: CancellationError.self) {
                _ = try await submit.value
            }
            #expect(try await cancel.value == link)
        }

        #expect(slot.pending == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)

        let verification = RouterPendingLinkPersistenceDriver(
            slot: RouterPendingLinkSlot<NineteenthReviewRoute>(),
            storage: RouterFilePendingLinkStorage(fileURL: fileURL)
        )
        #expect(try await verification.restore() == .noStoredLink)
    }

    /// AC-006 — the last accepted command decides the bytes, whether that is a
    /// save or a removal. A fix that simply drops every queued save fails here.
    @Test("The last accepted command decides the stored bytes")
    func lastAcceptedCommandDecidesStoredBytes() async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewRoute>(currentVersion: 1)
        let storage = NineteenthReviewRecordingStorage(data: nil)
        let store = RouterStore<NineteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .seconds(3_600)
        )
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            storage.unblockLoads()
            driver.stop()
        }
        _ = try await firstElement(from: storage.loads, what: "blocking load")

        let (reservations, reservationContinuation) = AsyncStream.makeStream(
            of: RouterDurabilityReservation.self
        )
        defer { reservationContinuation.finish() }
        try await RouterDurabilityTestSupport.withReservationObserver({ reservation in
            reservationContinuation.yield(reservation)
        }) {
            // save → remove → save, with acceptance proven at the synchronous boundary.
            let firstSave = Task(priority: .low) { @MainActor in try await driver.save() }
            defer { firstSave.cancel() }
            #expect(try await firstElement(
                from: reservations,
                what: "first snapshot save reservation"
            ) == .init(ticket: 0, command: .save))

            let remove = Task(priority: .high) { @MainActor in try await driver.removeSnapshot() }
            defer { remove.cancel() }
            #expect(try await firstElement(
                from: reservations,
                what: "snapshot remove reservation"
            ) == .init(ticket: 1, command: .remove))

            guard case .applied = await store.perform(.push(.current)) else {
                Issue.record("the replacement navigation was not accepted")
                return
            }
            let lastSave = Task { @MainActor in try await driver.save() }
            defer { lastSave.cancel() }
            #expect(try await firstElement(
                from: reservations,
                what: "last snapshot save reservation"
            ) == .init(ticket: 2, command: .save))

            storage.releaseLoad()
            _ = try await activation.value
            try await firstSave.value
            try await remove.value
            try await lastSave.value
        }

        let state = storage.state
        #expect(state.operations.last == "save", "storage order: \(state.operations)")
        let stored = try #require(state.file)
        #expect(try codec.decode(stored).root == store.state.root)
    }

    /// AC-007 — a failed command reports its failure and never blocks the
    /// commands accepted after it.
    @Test("A failed save still lets a later removal run")
    func failedSaveStillLetsLaterRemovalRun() async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewRoute>(currentVersion: 1)
        let storage = NineteenthReviewFailingStorage(mode: .failsSave)
        let store = RouterStore<NineteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        defer { driver.stop() }
        _ = try await driver.activate()

        await #expect(throws: (any Error).self) { try await driver.save() }
        try await driver.removeSnapshot()
        #expect(storage.state.operations == ["remove"])
    }

    /// AC-007 — a removal that fails is surfaced, not reported as done.
    @Test("A failed removal is reported to the caller")
    func failedRemovalIsReportedToTheCaller() async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewRoute>(currentVersion: 1)
        let storage = NineteenthReviewFailingStorage(mode: .failsRemove)
        let store = RouterStore<NineteenthReviewRoute>()
        let driver = RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
        defer { driver.stop() }
        _ = try await driver.activate()

        await #expect(throws: (any Error).self) { try await driver.removeSnapshot() }
        if case .failed = driver.status {} else {
            Issue.record("a failed removal left status \(driver.status)")
        }
        // The driver still accepts work after the failure.
        _ = await store.perform(.push(.current))
        try await driver.save()
        #expect(storage.state.operations == ["save"])
    }
}

@Suite("Nineteenth review initial restore phase", .timeLimit(.minutes(1)))
@MainActor
struct RouterNineteenthReviewRestorePhaseTests {
    private func makeDriver(
        _ storage: NineteenthReviewRecordingStorage,
        store: RouterStore<NineteenthReviewFragileRoute>,
        codec: RouterSnapshotCodec<NineteenthReviewFragileRoute>
    ) -> RouterRestorationDriver<NineteenthReviewFragileRoute> {
        RouterRestorationDriver(
            store: store,
            codec: codec,
            storage: storage,
            saveDebounce: .zero
        )
    }

    /// AC-010 — a natural last detach follows the same phase rule as a caller
    /// cancellation, whatever a concurrent save did.
    @Test(
        "A natural last detach keeps an unfinished restore retryable",
        arguments: NineteenthReviewSaveScenario.allCases
    )
    func naturalLastDetachKeepsUnfinishedRestoreRetryable(
        scenario: NineteenthReviewSaveScenario
    ) async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewFragileRoute>(currentVersion: 1)
        let storage = NineteenthReviewRecordingStorage(
            data: try codec.encode(.rootStack(path: [.saved]))
        )
        let store = RouterStore<NineteenthReviewFragileRoute>()
        let driver = makeDriver(storage, store: store, codec: codec)
        let owner = UUID()
        let attachment = Task { @MainActor in try await driver.attach(owner) }
        defer {
            attachment.cancel()
            storage.unblockLoads()
            driver.stop()
        }
        _ = try await firstElement(from: storage.loads, what: "blocking load")

        if scenario == .failing {
            _ = await store.perform(.push(.broken))
        }
        var save: Task<Void, any Error>?
        switch scenario {
        case .none:
            break
        case .succeeding:
            save = Task { @MainActor in try await driver.save() }
            try await waitUntil("the save reaches storage") { driver.status == .saving }
        case .failing:
            save = Task { @MainActor in try await driver.save() }
            try await waitUntil("the save fails") {
                if case .failed = driver.status { return true }
                return false
            }
        }

        driver.detach(owner)
        #expect(driver.attachmentCount == 0)
        storage.unblockLoads()
        _ = try? await attachment.value
        _ = try? await save?.value

        let retry = try await driver.activate()
        #expect(
            storage.state.loadCount == 2,
            "the retry did not read storage again (activation: \(retry))"
        )
        if case .observationResumed = retry {
            Issue.record("the retry resumed observation instead of restoring")
        }
    }

    /// AC-010 — another live owner keeps the shared restore, so one detach
    /// must not tear it down or start a second load.
    @Test("Another owner keeps the shared restore alive")
    func anotherOwnerKeepsSharedRestoreAlive() async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewFragileRoute>(currentVersion: 1)
        let storage = NineteenthReviewRecordingStorage(
            data: try codec.encode(.rootStack(path: [.saved]))
        )
        let store = RouterStore<NineteenthReviewFragileRoute>()
        let driver = makeDriver(storage, store: store, codec: codec)
        let first = UUID()
        let second = UUID()
        let firstAttachment = Task { @MainActor in try await driver.attach(first) }
        let secondAttachment = Task { @MainActor in try await driver.attach(second) }
        defer {
            firstAttachment.cancel()
            secondAttachment.cancel()
            storage.unblockLoads()
            driver.stop()
        }
        _ = try await firstElement(from: storage.loads, what: "blocking load")
        try await waitUntil("both owners attach") { driver.attachmentCount == 2 }

        driver.detach(first)
        #expect(driver.attachmentCount == 1)
        #expect(store.eventObservationCount == 1)

        storage.releaseLoad()
        _ = try? await firstAttachment.value
        _ = try? await secondAttachment.value
        #expect(storage.state.loadCount == 1)
        #expect(store.eventObservationCount == 1)
    }

    /// AC-011 — an explicit stop keeps the existing resume-only policy even
    /// when the initial restore never finished.
    @Test("An explicit stop keeps the resume-only policy")
    func explicitStopKeepsResumeOnlyPolicy() async throws {
        let codec = try RouterSnapshotCodec<NineteenthReviewFragileRoute>(currentVersion: 1)
        let storage = NineteenthReviewRecordingStorage(
            data: try codec.encode(.rootStack(path: [.saved]))
        )
        let store = RouterStore<NineteenthReviewFragileRoute>()
        let driver = makeDriver(storage, store: store, codec: codec)
        let activation = Task { @MainActor in try await driver.activate() }
        defer {
            activation.cancel()
            storage.unblockLoads()
            driver.stop()
        }
        _ = try await firstElement(from: storage.loads, what: "blocking load")

        driver.stop()
        #expect(store.eventObservationCount == 0)

        let resumed = try await driver.activate()
        if case .observationResumed = resumed {} else {
            Issue.record("an explicit stop changed the activation policy: \(resumed)")
        }
        #expect(storage.state.loadCount == 1)
        #expect(store.eventObservationCount == 1)
    }
}

/// Pending-link storage whose removal always fails.
private final class NineteenthReviewFailingPendingLinkStorage: RouterPendingLinkStorage {
    private enum StorageError: Error {
        case injected
    }

    private let stored = Mutex<Data?>(nil)

    func load() throws -> Data? { stored.withLock { $0 } }

    func save(_ data: Data) throws {
        stored.withLock { $0 = data }
    }

    func remove() throws {
        throw StorageError.injected
    }
}

@Suite("Nineteenth review durability failure handling", .timeLimit(.minutes(1)))
@MainActor
struct RouterNineteenthReviewDurabilityFailureTests {
    /// AC-008 — durable failure is reported, but it never rewinds navigation
    /// the store already committed.
    @Test("A failed removal after a resume keeps the committed navigation")
    func failedRemovalAfterResumeKeepsCommittedNavigation() async throws {
        let link = PendingRouterLink<NineteenthReviewRoute>(
            url: try #require(URL(string: "innorouter://app/resume")),
            gatedRoute: .saved,
            plan: RouterPlan(state: .rootStack(path: [.saved]))
        )
        let storage = NineteenthReviewFailingPendingLinkStorage()
        let slot = RouterPendingLinkSlot(link)
        let driver = RouterPendingLinkPersistenceDriver(slot: slot, storage: storage)
        let store = RouterStore<NineteenthReviewRoute>()

        await #expect(throws: (any Error).self) {
            _ = try await driver.resume(on: store)
        }

        #expect(store.state.root == .stack(path: [.saved]))
        #expect(store.revision == 1)
        if case .failed = driver.status {} else {
            Issue.record("a failed removal left status \(driver.status)")
        }
    }
}
