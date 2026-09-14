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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

package actor RouterSnapshotStorageExecutor {
    let storage: any RouterSnapshotStorage

    init(storage: any RouterSnapshotStorage) {
        self.storage = storage
    }

    func load() throws -> Data? {
        try storage.load()
    }

    func save(_ data: Data) throws {
        try storage.save(data)
    }

    func remove() throws {
        try storage.remove()
    }
}
