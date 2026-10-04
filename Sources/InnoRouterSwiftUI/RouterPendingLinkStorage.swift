// MARK: - RouterPendingLinkStorage.swift
// InnoRouterSwiftUI - application-selected pending-link persistence
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// Application-selected transport for one encoded pending router link.
public protocol RouterPendingLinkStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func remove() throws
}

/// Atomic file-backed pending-link storage at an application-owned URL.
public struct RouterFilePendingLinkStorage: RouterPendingLinkStorage, Sendable {
    /// Provisional 7.0 safety limit, pending consumer-fixture/RSS calibration.
    /// This is a finite starting bound, not a release-calibrated guarantee.
    public static let defaultMaximumByteCount = 4 * 1_024 * 1_024

    public let fileURL: URL
    public let maximumByteCount: Int?

    /// Creates storage bounded by the provisional 4 MiB default.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.maximumByteCount = Self.defaultMaximumByteCount
    }

    /// Creates storage with a positive byte limit, or explicit unlimited reads
    /// and writes when `nil` is supplied. Unlimited storage is appropriate only
    /// for trusted, app-bounded input. A rejected write preserves existing bytes.
    public init(fileURL: URL, maximumByteCount: Int?) throws {
        if let maximumByteCount, maximumByteCount <= 0 {
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
