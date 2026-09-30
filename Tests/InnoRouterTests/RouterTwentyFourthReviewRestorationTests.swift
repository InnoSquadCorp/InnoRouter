import Foundation
import Synchronization
import Testing
import InnoRouter
@testable import InnoRouterSwiftUI

private enum TwentyFourthError: Error { case encode, load, remove, save, timeout }
enum TwentyFourthLoad: CaseIterable, Sendable {
    case missing, failed, cancelled, corrupt, snapshot
}
private enum TwentyFourthRoute: String, Route, Codable {
    case good, broken
    func encode(to encoder: any Encoder) throws {
        guard self != .broken else { throw TwentyFourthError.encode }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private final class TwentyFourthStorage: RouterSnapshotStorage {
    let removals: AsyncStream<Void>
    let loads: AsyncStream<Void>
    let saves: AsyncStream<Void>
    private let removalContinuation: AsyncStream<Void>.Continuation
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let saveContinuation: AsyncStream<Void>.Continuation
    private let removeBarrier = DispatchSemaphore(value: 0)
    private let loadBarrier = DispatchSemaphore(value: 0)
    private let saveBarrier = DispatchSemaphore(value: 0)
    private let removeFails: Bool
    private let saveFails: Bool
    private let loadResult: TwentyFourthLoad
    private let saved = Mutex<Data?>(nil)
    private let loadCounter = Mutex(0)

    init(removeFails: Bool = false, saveFails: Bool = false, loadResult: TwentyFourthLoad = .missing) {
        self.removeFails = removeFails
        self.saveFails = saveFails
        self.loadResult = loadResult
        (removals, removalContinuation) = AsyncStream.makeStream(of: Void.self)
        (loads, loadContinuation) = AsyncStream.makeStream(of: Void.self)
        (saves, saveContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    deinit {
        releaseRemove(); releaseLoad(); releaseSave()
        removalContinuation.finish(); loadContinuation.finish(); saveContinuation.finish()
    }
    var data: Data? { saved.withLock { $0 } }
    var loadCount: Int { loadCounter.withLock { $0 } }
    func releaseRemove() { removeBarrier.signal() }
    func releaseLoad() { loadBarrier.signal() }
    func releaseSave() { saveBarrier.signal() }
    func load() throws -> Data? {
        loadCounter.withLock { $0 += 1 }
        loadContinuation.yield()
        guard loadBarrier.wait(timeout: .now() + 5) == .success else { throw TwentyFourthError.timeout }
        switch loadResult {
        case .missing: return nil
        case .failed: throw TwentyFourthError.load
        case .cancelled: throw CancellationError()
        case .corrupt: return Data("not a snapshot".utf8)
        case .snapshot:
            return try RouterSnapshotCodec<TwentyFourthRoute>(currentVersion: 1)
                .encode(.rootStack(path: [.good]))
        }
    }
    func save(_ data: Data) throws {
        saveContinuation.yield()
        guard saveBarrier.wait(timeout: .now() + 5) == .success else { throw TwentyFourthError.timeout }
        if saveFails { throw TwentyFourthError.save }
        saved.withLock { $0 = data }
    }
    func remove() throws {
        removalContinuation.yield()
        guard removeBarrier.wait(timeout: .now() + 5) == .success else { throw TwentyFourthError.timeout }
        if removeFails { throw TwentyFourthError.remove }
        saved.withLock { $0 = nil }
    }
}

@Suite("Twenty-fourth review restoration status ownership", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RouterTwentyFourthReviewRestorationTests {
    @Test("Older removal must not hide a newer blocked activation", arguments: [false, true])
    func removalVersusActivation(removeFails: Bool) async throws {
        let storage = TwentyFourthStorage(removeFails: removeFails)
        let store = RouterStore<TwentyFourthRoute>()
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: storage
        )
        let removal = Task { try await driver.removeSnapshot() }
        var activation: Task<RouterRestorationDriverActivation<TwentyFourthRoute>, any Error>?
        defer {
            storage.releaseRemove(); storage.releaseLoad()
            removal.cancel(); activation?.cancel(); driver.stop()
        }
        _ = try await firstElement(from: storage.removals, what: "remove entered")
        let activating = Task { try await driver.activate() }
        activation = activating
        try await waitUntil("new activation is loading") { driver.status == .loading }
        storage.releaseRemove()
        if removeFails {
            await #expect(throws: TwentyFourthError.remove) { try await removal.value }
        } else {
            try await removal.value
        }
        _ = try await firstElement(from: storage.loads, what: "activation load is blocked")
        #expect(driver.status == .loading)
        #expect(driver.lastActivation == nil)
        #expect(store.revision == 0)
        storage.releaseLoad()
        #expect(try await activating.value == .noSnapshot)
        #expect(driver.status == .active)
    }

    @Test("Older activation must not erase a newer encode failure", arguments: TwentyFourthLoad.allCases)
    func activationVersusSaveFailure(load: TwentyFourthLoad) async throws {
        let storage = TwentyFourthStorage(loadResult: load)
        let store = RouterStore<TwentyFourthRoute>(initialState: .rootStack(path: [.broken]))
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: storage,
            saveDebounce: .seconds(3_600)
        )
        let activating = Task { try await driver.activate() }
        defer { storage.releaseLoad(); activating.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.loads, what: "old activation load entered")
        await #expect(throws: RouterSnapshotError.encodePayload("encode")) {
            try await driver.save()
        }
        let failure = driver.status
        #expect(failure == .failed("encodePayload(\"encode\")"))
        storage.releaseLoad()
        await verifyActivation(activating, load: load)
        #expect(driver.status == failure)
        #expect(store.state.root == .stack(path: [load == .snapshot ? .good : .broken]))
        #expect(store.revision == (load == .snapshot ? 1 : 0))
    }

    @Test("A save started before activation cannot replace loading", arguments: [false, true])
    func saveBeforeActivation(saveFails: Bool) async throws {
        let storage = TwentyFourthStorage(saveFails: saveFails)
        let store = RouterStore<TwentyFourthRoute>(initialPath: [.good])
        let codec = try RouterSnapshotCodec<TwentyFourthRoute>(currentVersion: 1)
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let saving = Task { try await driver.save() }
        var activation: Task<RouterRestorationDriverActivation<TwentyFourthRoute>, any Error>?
        defer {
            storage.releaseSave(); storage.releaseLoad()
            saving.cancel(); activation?.cancel(); driver.stop()
        }
        _ = try await firstElement(from: storage.saves, what: "old save entered")
        let activating = Task { try await driver.activate() }
        activation = activating
        try await waitUntil("new activation owns loading") { driver.status == .loading }
        storage.releaseSave()
        try await verifySave(saving, fails: saveFails)
        _ = try await firstElement(from: storage.loads, what: "new load entered")
        #expect(driver.status == .loading)
        storage.releaseLoad()
        await verifyActivation(activating, load: .missing)
        #expect(driver.status == .active)
        #expect(store.revision == 0)
        if saveFails { #expect(storage.data == nil) } else {
            #expect(try codec.decode(#require(storage.data)) == store.state)
        }
    }

    @Test("A newer manual save survives activation cleanup", arguments: [TwentyFourthLoad.missing, .failed, .cancelled], [false, true])
    func saveAfterActivation(load: TwentyFourthLoad, saveFails: Bool) async throws {
        let storage = TwentyFourthStorage(saveFails: saveFails, loadResult: load)
        let store = RouterStore<TwentyFourthRoute>(initialPath: [.good])
        let codec = try RouterSnapshotCodec<TwentyFourthRoute>(currentVersion: 1)
        let driver = RouterRestorationDriver(store: store, codec: codec, storage: storage)
        let activating = Task { try await driver.activate() }
        var save: Task<Void, any Error>?
        defer {
            storage.releaseSave(); storage.releaseLoad()
            save?.cancel(); activating.cancel(); driver.stop()
        }
        _ = try await firstElement(from: storage.loads, what: "old load entered")
        let saving = Task { try await driver.save() }
        save = saving
        try await waitUntil("new save owns saving") { driver.status == .saving }
        storage.releaseLoad()
        await verifyActivation(activating, load: load)
        _ = try await firstElement(from: storage.saves, what: "new save entered")
        #expect(driver.status == .saving)
        storage.releaseSave()
        try await verifySave(saving, fails: saveFails)
        #expect(driver.status == (saveFails ? .failed("save") : (load == .missing ? .active : .inactive)))
        #expect(store.revision == 0)
        if saveFails { #expect(storage.data == nil) } else {
            #expect(try codec.decode(#require(storage.data)) == store.state)
        }
    }

    @Test("A newer removal survives activation cleanup", arguments: [TwentyFourthLoad.missing, .failed, .cancelled], [false, true])
    func removeAfterActivation(load: TwentyFourthLoad, removeFails: Bool) async throws {
        let storage = TwentyFourthStorage(removeFails: removeFails, loadResult: load)
        let driver = RouterRestorationDriver(
            store: RouterStore<TwentyFourthRoute>(), codec: try .init(currentVersion: 1), storage: storage
        )
        let (reservations, continuation) = AsyncStream<RouterDurabilityReservation>.makeStream()
        let activating = Task { try await driver.activate() }
        var removal: Task<Void, any Error>?
        defer {
            storage.releaseRemove(); storage.releaseLoad(); continuation.finish()
            removal?.cancel(); activating.cancel(); driver.stop()
        }
        _ = try await firstElement(from: storage.loads, what: "old load entered")
        let removing = Task {
            try await RouterDurabilityTestSupport.withReservationObserver({ continuation.yield($0) }) {
                try await driver.removeSnapshot()
            }
        }
        removal = removing
        let ticket = try await firstElement(from: reservations, what: "new removal accepted")
        #expect(ticket.command == .remove)
        storage.releaseLoad()
        await verifyActivation(activating, load: load)
        _ = try await firstElement(from: storage.removals, what: "new removal entered")
        storage.releaseRemove()
        if removeFails {
            await #expect(throws: TwentyFourthError.remove) { try await removing.value }
        } else { try await removing.value }
        #expect(driver.status == (removeFails ? .failed("remove") : (load == .missing ? .active : .inactive)))
    }

    @Test("An automatic encode failure survives older activation", arguments: [TwentyFourthLoad.missing, .failed, .cancelled])
    func automaticFailureAfterActivation(load: TwentyFourthLoad) async throws {
        let storage = TwentyFourthStorage(loadResult: load)
        let store = RouterStore<TwentyFourthRoute>()
        let driver = RouterRestorationDriver(
            store: store, codec: try .init(currentVersion: 1), storage: storage, saveDebounce: .zero
        )
        let activating = Task { try await driver.activate() }
        defer { storage.releaseLoad(); activating.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.loads, what: "old load entered")
        guard case .applied = await store.perform(.push(.broken)) else {
            Issue.record("Expected a committed navigation"); return
        }
        let failure = RouterRestorationDriverStatus.failed("encodePayload(\"encode\")")
        try await waitUntil("automatic encode fails") { driver.status == failure }
        storage.releaseLoad()
        await verifyActivation(activating, load: load)
        #expect(driver.status == failure)
        #expect(store.state.root == .stack(path: [.broken]))
        #expect(store.revision == 1)
    }

    @Test("Already-active calls do not steal a save's status", arguments: [false, true])
    func alreadyActiveDoesNotStealStatus(saveFails: Bool) async throws {
        let storage = TwentyFourthStorage(saveFails: saveFails)
        storage.releaseLoad()
        let driver = RouterRestorationDriver(
            store: RouterStore<TwentyFourthRoute>(), codec: try .init(currentVersion: 1), storage: storage
        )
        _ = try await driver.activate()
        let saving = Task { try await driver.save() }
        defer { storage.releaseSave(); saving.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.saves, what: "save entered")
        #expect(try await driver.activate() == .alreadyActive)
        #expect(driver.status == .saving)
        storage.releaseSave()
        try await verifySave(saving, fails: saveFails)
        #expect(driver.status == (saveFails ? .failed("save") : .active))
        #expect(storage.loadCount == 1)
    }

    @Test("Stop and restart revoke old load publication without replaying")
    func stopDuringActivation() async throws {
        let storage = TwentyFourthStorage()
        let store = RouterStore<TwentyFourthRoute>(initialPath: [.good])
        let driver = RouterRestorationDriver(store: store, codec: try .init(currentVersion: 1), storage: storage)
        let activating = Task { try await driver.activate() }
        defer { storage.releaseLoad(); storage.releaseSave(); activating.cancel(); driver.stop() }
        _ = try await firstElement(from: storage.loads, what: "load before stop")
        driver.stop()
        #expect(driver.status == .inactive)
        await #expect(throws: CancellationError.self) { _ = try await activating.value }
        #expect(try await driver.activate() == .observationResumed)
        #expect(driver.status == .active)
        storage.releaseLoad(); storage.releaseSave()
        try await driver.save()
        #expect(driver.status == .active)
        #expect(storage.loadCount == 1)
        #expect(store.revision == 0)
    }

    @Test("Debounce does not steal activation status before a save starts")
    func debounceDoesNotStealStatus() async throws {
        let storage = TwentyFourthStorage(loadResult: .snapshot)
        storage.releaseLoad()
        let sleeper = ManualRuntimeSleeper()
        var configuration = RouterStoreConfiguration<TwentyFourthRoute>()
        configuration.runtimeDependencies.sleep = { try await sleeper.sleep(for: $0) }
        let store = RouterStore(configuration: configuration)
        let codec = try RouterSnapshotCodec<TwentyFourthRoute>(currentVersion: 1)
        let driver = RouterRestorationDriver(
            store: store, codec: codec, storage: storage, saveDebounce: .seconds(30)
        )
        defer { storage.releaseSave(); driver.stop() }
        guard case .restored = try await driver.activate() else {
            Issue.record("Expected restored activation"); return
        }
        let delay = try await firstElement(from: sleeper.registrations, what: "automatic save debounce")
        #expect(delay == .seconds(30))
        #expect(driver.status == .active)
        await sleeper.resumeAll()
        _ = try await firstElement(from: storage.saves, what: "automatic save entered")
        #expect(driver.status == .saving)
        storage.releaseSave()
        try await waitUntil("automatic save completes") { driver.status == .active }
        #expect(try codec.decode(#require(storage.data)) == store.state)
        #expect(store.revision == 1)
        #expect(await sleeper.pendingCount == 0)
    }

    private func verifySave(_ task: Task<Void, any Error>, fails: Bool) async throws {
        if fails { await #expect(throws: TwentyFourthError.save) { try await task.value } }
        else { try await task.value }
    }

    private func verifyActivation(
        _ task: Task<RouterRestorationDriverActivation<TwentyFourthRoute>, any Error>,
        load: TwentyFourthLoad
    ) async {
        switch load {
        case .failed: await #expect(throws: TwentyFourthError.load) { _ = try await task.value }
        case .cancelled: await #expect(throws: CancellationError.self) { _ = try await task.value }
        case .corrupt: await #expect(throws: RouterSnapshotError.self) { _ = try await task.value }
        case .missing, .snapshot:
            do {
                let result = try await task.value
                if load == .missing { #expect(result == .noSnapshot) }
                else if case .restored(let outcome) = result {
                    guard case .applied = outcome.transition else { Issue.record("Expected applied restore"); return }
                } else { Issue.record("Expected restored result") }
            } catch { Issue.record(error) }
        }
    }
}
