// MARK: - RouterSnapshotStorage.swift
// InnoRouterSwiftUI - application-selected snapshot persistence
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

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

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> Data? {
        try RouterAtomicFileStore(fileURL: fileURL).load()
    }

    public func save(_ data: Data) throws {
        try RouterAtomicFileStore(fileURL: fileURL).save(data)
    }

    public func remove() throws {
        try RouterAtomicFileStore(fileURL: fileURL).remove()
    }
}
