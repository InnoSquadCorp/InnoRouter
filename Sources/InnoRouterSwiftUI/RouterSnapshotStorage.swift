// MARK: - RouterSnapshotStorage.swift
// InnoRouterSwiftUI - application-selected snapshot persistence
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// Application-selected transport for one opaque router snapshot.
///
/// Storage operations are synchronous by design and are executed by
/// ``RouterRestorationDriver`` on a private actor, never on the main actor.
/// Implementations should write atomically and must not add implicit cloud
/// synchronization or analytics behavior.
public protocol RouterSnapshotStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// Atomic file-backed snapshot storage at an application-owned URL.
public struct RouterFileSnapshotStorage: RouterSnapshotStorage, Sendable {
    public let fileURL: URL
    public let maximumByteCount: Int?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.maximumByteCount = nil
    }

    /// Creates storage that rejects reads and writes over the supplied byte
    /// count. Existing files are preserved when a write is rejected.
    public init(fileURL: URL, maximumByteCount: Int) throws {
        guard maximumByteCount > 0 else {
            throw RouterSnapshotError.invalidByteLimit(
                name: "maximumByteCount",
                value: maximumByteCount
            )
        }
        self.fileURL = fileURL
        self.maximumByteCount = maximumByteCount
    }

    public func load() throws -> Data? {
        try RouterAtomicFileStore(
            fileURL: fileURL,
            maximumByteCount: maximumByteCount
        ).load()
    }

    public func save(_ data: Data) throws {
        try RouterAtomicFileStore(
            fileURL: fileURL,
            maximumByteCount: maximumByteCount
        ).save(data)
    }

    public func remove() throws {
        try RouterAtomicFileStore(fileURL: fileURL).remove()
    }
}
