import Foundation
import Synchronization
import Testing

import InnoRouterCore
#if canImport(InnoRouterPersistenceContracts)
@testable import InnoRouterPersistenceContracts
#else
@testable import InnoRouterSwiftUI
#endif

private enum DurabilityStorageContractFailure: Error {
    case barrierTimedOut
}

/// All load/save/remove closures below call the real file adapter. The barrier
/// only holds the actor's synchronous load open to force the queue boundary.
private final class DurabilityContractFile: Sendable {
    let file: RouterFileSnapshotStorage
    let enteredLoad: AsyncStream<Void>
    private let loadContinuation: AsyncStream<Void>.Continuation
    private let releaseLoad = DispatchSemaphore(value: 0)
    let operations = Mutex<[String]>([])

    init(url: URL) {
        file = RouterFileSnapshotStorage(fileURL: url)
        (enteredLoad, loadContinuation) = AsyncStream.makeStream()
    }

    func unblock() { releaseLoad.signal() }

    func executor(blockLoad: Bool = false) -> RouterByteStoreExecutor {
        RouterByteStoreExecutor(
            load: {
                let result = try self.file.load()
                if blockLoad {
                    self.loadContinuation.yield(())
                    guard self.releaseLoad.wait(timeout: .now() + 10) == .success else {
                        throw DurabilityStorageContractFailure.barrierTimedOut
                    }
                }
                return result
            },
            save: { bytes in
                try self.file.save(bytes)
                self.operations.withLock { $0.append(String(decoding: bytes, as: UTF8.self)) }
            },
            remove: {
                try self.file.remove()
                self.operations.withLock { $0.append("remove") }
            }
        )
    }
}

@Suite("Production durability gate and file executor", .serialized, .timeLimit(.minutes(1)))
struct RouterDurabilityStorageContractTests {
    @Test("Reverse launch priorities cannot reorder accepted file saves")
    func acceptanceOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DurabilityContractFile(url: directory.appending(path: "bytes"))
        let executor = file.executor()
        let gate = RouterDurabilityGate()
        let tickets = (0..<64).map { _ in gate.reserve(.save) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in tickets.indices.reversed() {
                let ticket = tickets[index]
                group.addTask(priority: index.isMultiple(of: 2) ? .high : .background) {
                    defer { gate.finish(ticket) }
                    guard await gate.waitForTurn(ticket) else {
                        Issue.record("An explicit save was invalidated without a remove")
                        return
                    }
                    try await executor.save(Data("save-\(index)".utf8), ifCurrent: { gate.beginSave(ticket) })
                }
            }
            try await group.waitForAll()
        }
        #expect(file.operations.withLock { $0 } == (0..<64).map { "save-\($0)" })
        #expect(try file.file.load() == Data("save-63".utf8))
    }

    @Test("Remove revokes earlier saves and a newer accepted save follows removal")
    func removalAcceptanceOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DurabilityContractFile(url: directory.appending(path: "bytes"))
        try file.file.save(Data("original".utf8))
        let executor = file.executor()
        let gate = RouterDurabilityGate()
        let stale = gate.reserve(.save)
        let remove = gate.reserve(.remove)
        let newest = gate.reserve(.save)
        let newerTask = Task(priority: .high) {
            defer { gate.finish(newest) }
            #expect(await gate.waitForTurn(newest))
            try await executor.save(Data("newest".utf8), ifCurrent: { gate.beginSave(newest) })
        }
        let removeTask = Task(priority: .high) {
            defer { gate.finish(remove) }
            #expect(await gate.waitForTurn(remove))
            try await executor.remove()
        }
        #expect(!(await gate.waitForTurn(stale)))
        #expect(!gate.beginSave(stale))
        gate.finish(stale)
        try await removeTask.value
        try await newerTask.value
        #expect(file.operations.withLock { $0 } == ["remove", "newest"])
        #expect(try file.file.load() == Data("newest".utf8))
    }

    @Test("Cancellation invalidates a queued automatic save but preserves an explicit save", arguments: [false, true])
    func queuedInvalidationDistinguishesExplicitSave(automatic: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DurabilityContractFile(url: directory.appending(path: "bytes"))
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        let candidate = Data("candidate".utf8)
        try file.file.save(original)
        let executor = file.executor(blockLoad: true)
        let gate = RouterDurabilityGate()
        let load = Task { try await executor.load() }
        defer { file.unblock(); load.cancel() }
        var entered = file.enteredLoad.makeAsyncIterator()
        _ = try #require(await entered.next())
        let ticket = gate.reserve(.save, supersedable: automatic)
        let (enqueuing, didEnqueue) = AsyncStream<Void>.makeStream()
        defer { didEnqueue.finish() }
        let save = Task {
            defer { gate.finish(ticket) }
            #expect(await gate.waitForTurn(ticket))
            didEnqueue.yield(())
            try await executor.save(candidate, ifCurrent: { gate.beginSave(ticket) })
        }
        var enqueued = enqueuing.makeAsyncIterator()
        _ = try #require(await enqueued.next())
        // Like stop/detach: revoke automatic work while storage is occupied,
        // even though it passed waitForTurn. Explicit save remains durable.
        gate.invalidateSupersedableSaves()
        save.cancel()
        try file.file.save(replacement)
        file.unblock()
        #expect(try await load.value == original)
        try await save.value
        #expect(try file.file.load() == (automatic ? replacement : candidate))
        #expect(file.operations.withLock { $0 } == (automatic ? [] : ["candidate"]))
    }

    @Test("A remove accepted after waitForTurn prevents queued save resurrection")
    func queuedRemovalRevokesSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DurabilityContractFile(url: directory.appending(path: "bytes"))
        try file.file.save(Data("original".utf8))
        let executor = file.executor(blockLoad: true)
        let gate = RouterDurabilityGate()
        let load = Task { try await executor.load() }
        defer { file.unblock(); load.cancel() }
        var entered = file.enteredLoad.makeAsyncIterator()
        _ = try #require(await entered.next())
        let ticket = gate.reserve(.save)
        #expect(await gate.waitForTurn(ticket))
        let save = Task {
            defer { gate.finish(ticket) }
            try await executor.save(Data("must not resurrect".utf8), ifCurrent: { gate.beginSave(ticket) })
        }
        let removalTicket = gate.reserve(.remove)
        let remove = Task(priority: .high) {
            defer { gate.finish(removalTicket) }
            #expect(await gate.waitForTurn(removalTicket))
            try await executor.remove()
        }
        file.unblock()
        _ = try await load.value
        try await save.value
        try await remove.value
        #expect(file.operations.withLock { $0 } == ["remove"])
        #expect(try file.file.load() == nil)
    }

    @Test("An abandoned encode reservation and invalidated tail do not block the next write")
    func abandonedReservationsReleaseQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DurabilityContractFile(url: directory.appending(path: "bytes"))
        let executor = file.executor()
        let gate = RouterDurabilityGate()
        let first = gate.reserve(.save)
        let abandoned = gate.reserve(.save)
        let automatic = gate.reserve(.save, supersedable: true)
        let last = gate.reserve(.save)
        gate.finish(abandoned) // Codec failure before waitForTurn.
        gate.invalidateSupersedableSaves()
        #expect(!(await gate.waitForTurn(automatic)))
        gate.finish(automatic) // Completed out of order.
        let tail = Task {
            defer { gate.finish(last) }
            #expect(await gate.waitForTurn(last))
            try await executor.save(Data("tail".utf8), ifCurrent: { gate.beginSave(last) })
        }
        #expect(await gate.waitForTurn(first))
        try await executor.save(Data("head".utf8), ifCurrent: { gate.beginSave(first) })
        gate.finish(first)
        try await tail.value
        #expect(file.operations.withLock { $0 } == ["head", "tail"])
        #expect(try file.file.load() == Data("tail".utf8))
    }

    @Test("An already begun save completes before its later remove")
    func removalAfterClaim() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DurabilityContractFile(url: directory.appending(path: "bytes"))
        let executor = file.executor()
        let gate = RouterDurabilityGate()
        let save = gate.reserve(.save, supersedable: true)
        #expect(await gate.waitForTurn(save))
        #expect(gate.beginSave(save))
        let remove = gate.reserve(.remove)
        gate.invalidateSupersedableSaves()
        let removal = Task {
            defer { gate.finish(remove) }
            #expect(await gate.waitForTurn(remove))
            try await executor.remove()
        }
        // Claiming I/O is the acceptance boundary: cancellation cannot undo
        // an already started synchronous adapter, but removal stays after it.
        try await executor.save(Data("started".utf8))
        gate.finish(save)
        try await removal.value
        #expect(file.operations.withLock { $0 } == ["started", "remove"])
        #expect(try file.file.load() == nil)
    }
}

extension RouterDurabilityStorageContractTests {
    @Test("A rejected real file write releases its reservation for the next accepted write")
    func failedWriteReleasesQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = DurabilityContractFile(url: directory.appending(path: "bytes"))
        let original = Data("original".utf8)
        try file.file.save(original)
        let executor = file.executor()
        let gate = RouterDurabilityGate()
        let failed = gate.reserve(.save)
        let next = gate.reserve(.save)
        let tail = Task {
            defer { gate.finish(next) }
            #expect(await gate.waitForTurn(next))
            try await executor.save(Data("next".utf8), ifCurrent: { gate.beginSave(next) })
        }
        #expect(await gate.waitForTurn(failed))
        await #expect(throws: RouterSnapshotError.encodedDataTooLarge(
            actualByteCount: 4 * 1_024 * 1_024 + 1,
            maximumByteCount: 4 * 1_024 * 1_024
        )) {
            try await executor.save(Data(repeating: 0x55, count: 4 * 1_024 * 1_024 + 1), ifCurrent: { gate.beginSave(failed) })
        }
        #expect(try file.file.load() == original)
        gate.finish(failed)
        try await tail.value
        #expect(file.operations.withLock { $0 } == ["next"])
        #expect(try file.file.load() == Data("next".utf8))
    }
}
