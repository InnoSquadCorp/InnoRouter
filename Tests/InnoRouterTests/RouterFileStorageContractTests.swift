import Foundation
import Synchronization
import Testing

import InnoRouterCore
#if canImport(InnoRouterPersistenceContracts)
import InnoRouterPersistenceContracts
#else
import InnoRouterSwiftUI
#endif

@Suite("Production file storage contracts", .serialized, .timeLimit(.minutes(1)))
struct RouterFileStorageContractTests {
    @Test("Default snapshot file storage rejects limit+1 before replacing existing bytes")
    func defaultSnapshotWriteIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "snapshot")
        let storage = RouterFileSnapshotStorage(fileURL: url)
        let prior = Data("keep me".utf8)
        try storage.save(prior)
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: 4 * 1_024 * 1_024 + 1, maximumByteCount: 4 * 1_024 * 1_024)) {
            try storage.save(Data(repeating: 0x41, count: 4 * 1_024 * 1_024 + 1))
        }
        #expect(try Data(contentsOf: url) == prior)
    }

    @Test("Default pending-link file storage rejects limit+1 before replacing existing bytes")
    func defaultPendingWriteIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "pending")
        let storage = RouterFilePendingLinkStorage(fileURL: url)
        let prior = Data("keep me".utf8)
        try storage.save(prior)
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: 4 * 1_024 * 1_024 + 1, maximumByteCount: 4 * 1_024 * 1_024)) {
            try storage.save(Data(repeating: 0x41, count: 4 * 1_024 * 1_024 + 1))
        }
        #expect(try Data(contentsOf: url) == prior)
    }
}

private enum ContractFileKind: String, CaseIterable, Sendable {
    case snapshot, pendingLink

    func load(_ url: URL, limit: Int?) throws -> Data? {
        switch self {
        case .snapshot: try RouterFileSnapshotStorage(fileURL: url, maximumByteCount: limit).load()
        case .pendingLink: try RouterFilePendingLinkStorage(fileURL: url, maximumByteCount: limit).load()
        }
    }

    func save(_ data: Data, at url: URL, limit: Int?) throws {
        switch self {
        case .snapshot: try RouterFileSnapshotStorage(fileURL: url, maximumByteCount: limit).save(data)
        case .pendingLink: try RouterFilePendingLinkStorage(fileURL: url, maximumByteCount: limit).save(data)
        }
    }

    func remove(_ url: URL) throws {
        switch self {
        case .snapshot: try RouterFileSnapshotStorage(fileURL: url).remove()
        case .pendingLink: try RouterFilePendingLinkStorage(fileURL: url).remove()
        }
    }

    func loadDefault(_ url: URL) throws -> Data? {
        switch self {
        case .snapshot: try RouterFileSnapshotStorage(fileURL: url).load()
        case .pendingLink: try RouterFilePendingLinkStorage(fileURL: url).load()
        }
    }

    func saveDefault(_ data: Data, at url: URL) throws {
        switch self {
        case .snapshot: try RouterFileSnapshotStorage(fileURL: url).save(data)
        case .pendingLink: try RouterFilePendingLinkStorage(fileURL: url).save(data)
        }
    }
}

private struct ContractFileFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var url: URL { directory.appending(path: "nested/bytes") }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

extension RouterFileStorageContractTests {
    @Test("Both file adapters advertise the same finite provisional default")
    func advertisedDefault() {
        let url = URL(fileURLWithPath: "/unused")
        #expect(RouterFileSnapshotStorage.defaultMaximumByteCount == 4 * 1_024 * 1_024)
        #expect(RouterFilePendingLinkStorage.defaultMaximumByteCount == 4 * 1_024 * 1_024)
        #expect(RouterFileSnapshotStorage(fileURL: url).maximumByteCount == 4 * 1_024 * 1_024)
        #expect(RouterFilePendingLinkStorage(fileURL: url).maximumByteCount == 4 * 1_024 * 1_024)
    }

    @Test("Missing load/remove and repeated remove are harmless", arguments: ContractFileKind.allCases)
    fileprivate func missingFile(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        #expect(try kind.loadDefault(fixture.url) == nil)
        try kind.remove(fixture.url)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        try kind.saveDefault(Data(), at: fixture.url)
        #expect(try kind.loadDefault(fixture.url) == Data())
        try kind.remove(fixture.url)
        try kind.remove(fixture.url)
        #expect(try kind.loadDefault(fixture.url) == nil)
    }

    @Test("Default accepts exactly 4 MiB and rejects oversized read without changing the file", arguments: ContractFileKind.allCases)
    fileprivate func defaultReadBoundary(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        let limit = 4 * 1_024 * 1_024
        let boundary = Data(repeating: 0x41, count: limit)
        try kind.saveDefault(boundary, at: fixture.url)
        #expect(try kind.loadDefault(fixture.url) == boundary)
        let oversized = boundary + Data([0x42])
        try oversized.write(to: fixture.url, options: .atomic)
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: limit + 1, maximumByteCount: limit)) {
            try kind.loadDefault(fixture.url)
        }
        #expect(try Data(contentsOf: fixture.url) == oversized)
    }

    @Test("Positive limits enforce exact and limit+1 reads/writes across chunk boundaries", arguments: ContractFileKind.allCases, [1, 65_536, 65_537])
    fileprivate func explicitReadWriteBoundary(kind: ContractFileKind, limit: Int) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        let boundary = Data(repeating: 0x43, count: limit)
        try kind.save(boundary, at: fixture.url, limit: limit)
        #expect(try kind.load(fixture.url, limit: limit) == boundary)
        let oversized = boundary + Data([0x44])
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: limit + 1, maximumByteCount: limit)) {
            try kind.save(oversized, at: fixture.url, limit: limit)
        }
        #expect(try Data(contentsOf: fixture.url) == boundary)
        try oversized.write(to: fixture.url, options: .atomic)
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: limit + 1, maximumByteCount: limit)) {
            try kind.load(fixture.url, limit: limit)
        }
        #expect(try Data(contentsOf: fixture.url) == oversized)
    }

    @Test("Invalid limits fail before filesystem access", arguments: ContractFileKind.allCases, [Int.min, -1, 0])
    fileprivate func invalidLimits(kind: ContractFileKind, limit: Int) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        #expect(throws: RouterSnapshotError.invalidByteLimit(name: "maximumByteCount", value: limit)) {
            try kind.save(Data(), at: fixture.url, limit: limit)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("Explicit nil permits bytes above the default", arguments: ContractFileKind.allCases)
    fileprivate func unlimitedOptOut(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        let bytes = Data(repeating: 0x45, count: 4 * 1_024 * 1_024 + 1)
        try kind.save(bytes, at: fixture.url, limit: nil)
        #expect(try kind.load(fixture.url, limit: nil) == bytes)
    }

    @Test("Rejected writes do not create directories", arguments: ContractFileKind.allCases)
    fileprivate func rejectionHasNoFileSideEffect(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: 2, maximumByteCount: 1)) {
            try kind.save(Data([0, 1]), at: fixture.url, limit: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test("Oversized metadata is rejected before opening the bounded read", arguments: ContractFileKind.allCases)
    fileprivate func metadataRejectsBeforeRead(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        try kind.save(Data(repeating: 0x46, count: 129), at: fixture.url, limit: nil)
        let hookWasCalled = Mutex(false)
        RouterByteStoreTestSupport.$afterBoundedFileMetadataRead.withValue({
            hookWasCalled.withLock { $0 = true }
        }) {
            #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: 129, maximumByteCount: 128)) {
                try kind.load(fixture.url, limit: 128)
            }
        }
        #expect(!hookWasCalled.withLock { $0 })
    }

    @Test("A file grown after metadata is still bounded by actual bytes", arguments: ContractFileKind.allCases)
    fileprivate func metadataReadRace(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        let limit = 65_536
        try kind.save(Data([0x47]), at: fixture.url, limit: limit)
        let grown = Data(repeating: 0x48, count: limit * 2)
        let hookWasCalled = Mutex(false)
        RouterByteStoreTestSupport.$afterBoundedFileMetadataRead.withValue({
            hookWasCalled.withLock { $0 = true }
            try grown.write(to: fixture.url, options: .atomic)
        }) {
            // Actual size is twice the budget, but the bounded reader only reads
            // budget + one sentinel byte, so it must report that lower bound.
            #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: limit + 1, maximumByteCount: limit)) {
                try kind.load(fixture.url, limit: limit)
            }
        }
        #expect(hookWasCalled.withLock { $0 })
        #expect(try Data(contentsOf: fixture.url) == grown)
    }

    @Test("A shortened file returns complete new bytes rather than stale metadata", arguments: ContractFileKind.allCases)
    fileprivate func metadataShrinkRace(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        try kind.save(Data(repeating: 0x49, count: 128), at: fixture.url, limit: 128)
        let shortened = Data([0x50])
        let loaded = try RouterByteStoreTestSupport.$afterBoundedFileMetadataRead.withValue({
            try shortened.write(to: fixture.url, options: .atomic)
        }) {
            try kind.load(fixture.url, limit: 128)
        }
        #expect(loaded == shortened)
    }

    @Test("Concurrent file replacements expose only complete old or new bytes", arguments: ContractFileKind.allCases)
    fileprivate func atomicCompleteBytes(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        let limit = 256 * 1_024
        let first = Data(repeating: 0x51, count: limit)
        let second = Data(repeating: 0x52, count: limit)
        try kind.save(first, at: fixture.url, limit: limit)
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            do {
                for index in 0..<100 {
                    if worker < 2 {
                        try kind.save(index.isMultiple(of: 2) ? first : second, at: fixture.url, limit: limit)
                    } else {
                        let loaded = try kind.load(fixture.url, limit: limit)
                        if loaded != first && loaded != second {
                            failures.withLock { $0.append("Observed partial or absent bytes") }
                        }
                    }
                }
            } catch {
                failures.withLock { $0.append(String(describing: error)) }
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
        let final = try kind.load(fixture.url, limit: limit)
        #expect(final == first || final == second)
    }
}

extension RouterFileStorageContractTests {
    @Test("Sparse 1 GiB file is rejected by metadata without reading its contents", arguments: ContractFileKind.allCases)
    fileprivate func sparseOversizedFile(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        try kind.saveDefault(Data(), at: fixture.url)
        let handle = try FileHandle(forWritingTo: fixture.url)
        let size = 1_024 * 1_024 * 1_024
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let hookWasCalled = Mutex(false)
        RouterByteStoreTestSupport.$afterBoundedFileMetadataRead.withValue({
            hookWasCalled.withLock { $0 = true }
        }) {
            #expect(throws: RouterSnapshotError.encodedDataTooLarge(actualByteCount: size, maximumByteCount: 4 * 1_024 * 1_024)) {
                try kind.loadDefault(fixture.url)
            }
        }
        #expect(!hookWasCalled.withLock { $0 })
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == size)
    }

    @Test("An explicit Int.max bound handles small real files without overflow", arguments: ContractFileKind.allCases)
    fileprivate func maximumIntegerLimit(kind: ContractFileKind) throws {
        let fixture = ContractFileFixture()
        defer { fixture.remove() }
        let bytes = Data([0x53, 0x54])
        try kind.save(bytes, at: fixture.url, limit: Int.max)
        #expect(try kind.load(fixture.url, limit: Int.max) == bytes)
    }
}
