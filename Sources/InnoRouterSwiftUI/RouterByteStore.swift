// MARK: - RouterByteStore.swift
// InnoRouterSwiftUI - shared byte persistence used by snapshots and links
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// Package-only synchronization point for deterministic file mutation tests.
/// Production calls use the nil default and execute no additional work.
package enum RouterByteStoreTestSupport {
    @TaskLocal package static var afterBoundedFileMetadataRead: (@Sendable () throws -> Void)?
}

/// Atomic file-backed byte persistence at an application-owned URL.
///
/// `RouterFileSnapshotStorage` and `RouterFilePendingLinkStorage` are separate
/// public types on separate public protocols, and stay that way — but their
/// bodies were the same three operations written twice. Atomic-write semantics
/// duplicated across two files can drift: a fix applied to one (intermediate
/// directory creation, say) silently leaves the other behind. Both now delegate
/// here, so there is one definition of what "atomic file storage" means.
struct RouterAtomicFileStore: Sendable {
    let fileURL: URL
    var maximumByteCount: Int?

    init(fileURL: URL, maximumByteCount: Int? = nil) {
        self.fileURL = fileURL
        self.maximumByteCount = maximumByteCount
    }

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let maximumByteCount else { return try Data(contentsOf: fileURL) }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let fileSize = (attributes[.size] as? NSNumber)?.intValue,
           fileSize > maximumByteCount {
            throw RouterSnapshotError.encodedDataTooLarge(
                actualByteCount: fileSize,
                maximumByteCount: maximumByteCount
            )
        }
        try RouterByteStoreTestSupport.afterBoundedFileMetadataRead?()

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        let chunkSize = 64 * 1_024
        while data.count < maximumByteCount {
            let remaining = maximumByteCount - data.count
            guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        if let overflow = try handle.read(upToCount: 1), !overflow.isEmpty {
            let actual = maximumByteCount == Int.max ? Int.max : maximumByteCount + 1
            throw RouterSnapshotError.encodedDataTooLarge(
                actualByteCount: actual,
                maximumByteCount: maximumByteCount
            )
        }
        return data
    }

    func save(_ data: Data) throws {
        if let maximumByteCount, data.count > maximumByteCount {
            throw RouterSnapshotError.encodedDataTooLarge(
                actualByteCount: data.count,
                maximumByteCount: maximumByteCount
            )
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Serializes an application's synchronous storage off the main actor.
///
/// Snapshot and pending-link persistence each had their own actor with the same
/// three forwarding methods, differing only in the protocol they held. Closures
/// let one actor serve both without either public protocol gaining a common
/// refinement, which would have changed their published surface.
///
/// The operations stay synchronous because `RouterSnapshotStorage` and
/// `RouterPendingLinkStorage` are synchronous by design; this actor is what
/// keeps them off the main actor.
package actor RouterByteStoreExecutor {
    private let loadBytes: @Sendable () throws -> Data?
    private let saveBytes: @Sendable (Data) throws -> Void
    private let removeBytes: @Sendable () throws -> Void

    init(
        load: @escaping @Sendable () throws -> Data?,
        save: @escaping @Sendable (Data) throws -> Void,
        remove: @escaping @Sendable () throws -> Void
    ) {
        self.loadBytes = load
        self.saveBytes = save
        self.removeBytes = remove
    }

    func load() throws -> Data? { try loadBytes() }
    func save(_ data: Data) throws { try saveBytes(data) }
    func remove() throws { try removeBytes() }
}
