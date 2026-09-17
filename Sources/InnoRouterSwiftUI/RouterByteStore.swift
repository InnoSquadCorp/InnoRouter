// MARK: - RouterByteStore.swift
// InnoRouterSwiftUI - shared byte persistence used by snapshots and links
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

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

    func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    func save(_ data: Data) throws {
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
actor RouterByteStoreExecutor {
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
