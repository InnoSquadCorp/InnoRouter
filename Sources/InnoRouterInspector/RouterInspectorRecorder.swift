import Foundation
import Observation

import InnoRouterCore
import InnoRouterSwiftUI

/// A bounded, opt-in timeline recorder for InnoRouter event streams.
@MainActor
@Observable
public final class RouterInspectorRecorder {
    public private(set) var entries: [RouterInspectorEntry] = []
    public private(set) var isPaused = false
    public private(set) var pauseOnRejection = false
    public private(set) var bookmarkedEntryIDs: Set<RouterInspectorEntry.ID> = []
    public let capacity: Int
    public let importLimits: RouterInspectorImportLimits

    @ObservationIgnored private var transitionStartTimes: [String: Date] = [:]
    @ObservationIgnored private var transitionLastEventTimes: [String: Date] = [:]

    public init(
        capacity: Int = 500,
        importLimits: RouterInspectorImportLimits = .default
    ) {
        self.capacity = max(1, capacity)
        self.importLimits = importLimits
    }

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
    }

    public func setPauseOnRejection(_ enabled: Bool) {
        pauseOnRejection = enabled
    }

    public func toggleBookmark(_ entryID: RouterInspectorEntry.ID) {
        if bookmarkedEntryIDs.contains(entryID) {
            bookmarkedEntryIDs.remove(entryID)
        } else if entries.contains(where: { $0.id == entryID }) {
            bookmarkedEntryIDs.insert(entryID)
        }
    }

    public func isBookmarked(_ entryID: RouterInspectorEntry.ID) -> Bool {
        bookmarkedEntryIDs.contains(entryID)
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
        bookmarkedEntryIDs.removeAll(keepingCapacity: true)
        transitionStartTimes.removeAll(keepingCapacity: true)
        transitionLastEventTimes.removeAll(keepingCapacity: true)
    }

    public func snapshot(generatedAt: Date = Date()) -> RouterInspectorSnapshot {
        RouterInspectorSnapshot(
            generatedAt: generatedAt,
            entries: entries,
            bookmarkedEntryIDs: bookmarkedEntryIDs
        )
    }

    public func encodedSnapshot(
        generatedAt: Date = Date(),
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        try encoder.encode(snapshot(generatedAt: generatedAt))
    }

    /// Creates a support-ready envelope around the current redacted timeline.
    /// Custom formatters remain an explicit opt-in to application data and
    /// should be reviewed by the app before sharing the resulting bundle.
    public func diagnosticBundle(
        platform: RouterPlatform = RouterPlatformCapabilities.current.platform,
        frameworkVersion: String = InnoRouterVersion.current,
        generatedAt: Date = Date()
    ) -> RouterInspectorDiagnosticBundle {
        RouterInspectorDiagnosticBundle(
            frameworkVersion: frameworkVersion,
            platform: platform,
            snapshot: snapshot(generatedAt: generatedAt)
        )
    }

    /// Encodes a diagnostic bundle with deterministic JSON key ordering.
    public func encodedDiagnosticBundle(
        platform: RouterPlatform = RouterPlatformCapabilities.current.platform,
        frameworkVersion: String = InnoRouterVersion.current,
        generatedAt: Date = Date()
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            diagnosticBundle(
                platform: platform,
                frameworkVersion: frameworkVersion,
                generatedAt: generatedAt
            )
        )
    }

    /// Imports a payload-redacted snapshot into the bounded timeline.
    public func importSnapshot(
        _ snapshot: RouterInspectorSnapshot,
        policy: RouterInspectorImportPolicy = .replace
    ) throws {
        guard snapshot.entries.count <= importLimits.maximumEntryCount else {
            throw RouterInspectorImportError.tooManyEntries(
                actualCount: snapshot.entries.count,
                maximumCount: importLimits.maximumEntryCount
            )
        }
        var seen: Set<UUID> = []
        for entry in snapshot.entries where !seen.insert(entry.id).inserted {
            throw RouterInspectorImportError.duplicateEntryID(entry.id)
        }

        switch policy {
        case .replace:
            entries = Array(snapshot.entries.suffix(capacity))
            let retainedIDs = Set(entries.map(\.id))
            bookmarkedEntryIDs = snapshot.bookmarkedEntryIDs.intersection(retainedIDs)
            transitionStartTimes.removeAll(keepingCapacity: true)
            transitionLastEventTimes.removeAll(keepingCapacity: true)
        case .append:
            let existingIDs = Set(entries.map(\.id))
            if let duplicate = snapshot.entries.first(where: { existingIDs.contains($0.id) }) {
                throw RouterInspectorImportError.duplicateEntryID(duplicate.id)
            }
            entries.append(contentsOf: snapshot.entries)
            let overflow = entries.count - capacity
            if overflow > 0 {
                entries.removeFirst(overflow)
            }
            let retainedIDs = Set(entries.map(\.id))
            bookmarkedEntryIDs.formUnion(snapshot.bookmarkedEntryIDs)
            bookmarkedEntryIDs.formIntersection(retainedIDs)
            pruneTransitionTiming()
        }
    }

    /// Decodes and imports an exported inspector snapshot.
    @discardableResult
    public func importSnapshot(
        from data: Data,
        policy: RouterInspectorImportPolicy = .replace,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> RouterInspectorSnapshot {
        try RouterInspectorImportPreflight.validate(data, limits: importLimits)
        let snapshot = try decoder.decode(RouterInspectorSnapshot.self, from: data)
        try importSnapshot(snapshot, policy: policy)
        return snapshot
    }

    /// Imports a supported diagnostic bundle and returns its environment metadata.
    /// Byte and entry limits are checked before decoding entries; failures leave
    /// the current timeline and bookmarks unchanged.
    @discardableResult
    public func importDiagnosticBundle(
        from data: Data,
        policy: RouterInspectorImportPolicy = .replace,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> RouterInspectorDiagnosticBundle {
        try RouterInspectorImportPreflight.validate(data, limits: importLimits, diagnosticBundle: true)
        let bundle = try decoder.decode(RouterInspectorDiagnosticBundle.self, from: data)
        try importSnapshot(bundle.snapshot, policy: policy)
        return bundle
    }

    /// Subscribes to any typed event stream with an explicit safe formatter.
    @discardableResult
    public func attach<Event: Sendable>(
        to stream: AsyncStream<Event>,
        domain: RouterInspectorDomain,
        formatter: RouterInspectorFormatter<Event>
    ) -> RouterInspectorSubscription {
        let task = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.record(domain: domain, description: formatter(event))
            }
        }
        return RouterInspectorSubscription(task: task)
    }

    /// Attaches the canonical InnoRouter 6 transition timeline. The default
    /// formatter records correlation and structural counts while redacting all
    /// route payloads and policy messages.
    @discardableResult
    public func attach<R: Route>(
        to store: RouterStore<R>,
        formatter: RouterInspectorFormatter<RouterEvent<R>>? = nil
    ) -> RouterInspectorSubscription {
        attach(
            to: store.events,
            domain: .router,
            formatter: formatter ?? redactedRouterFormatter()
        )
    }

    /// Adds an explicitly formatted entry. Route objects are never retained.
    public func record(
        domain: RouterInspectorDomain,
        description: RouterInspectorEventDescription,
        timestamp: Date = Date()
    ) {
        guard !isPaused else { return }
        var metadata = description.metadata
        recordTiming(
            name: description.name,
            metadata: &metadata,
            timestamp: timestamp
        )
        entries.append(
            RouterInspectorEntry(
                timestamp: timestamp,
                domain: domain,
                name: description.name,
                outcome: description.outcome,
                metadata: metadata,
                state: description.state,
                diff: description.diff,
                replay: description.replay
            )
        )
        let overflow = entries.count - capacity
        if overflow > 0 {
            let removed = entries.prefix(overflow).map(\.id)
            entries.removeFirst(overflow)
            bookmarkedEntryIDs.subtract(removed)
            pruneTransitionTiming()
        }
        if pauseOnRejection, description.outcome == .rejected {
            isPaused = true
        }
    }

    /// Compares any two captured redacted states in this timeline.
    public func comparison(
        from beforeID: RouterInspectorEntry.ID,
        to afterID: RouterInspectorEntry.ID
    ) -> RouterInspectorStateDiff? {
        RouterInspectorComparison.states(
            at: beforeID,
            and: afterID,
            in: snapshot()
        )
    }

    private func recordTiming(
        name: String,
        metadata: inout [String: String],
        timestamp: Date
    ) {
        guard let transitionID = metadata["transitionID"] else { return }
        if name == "transition.started" {
            transitionStartTimes[transitionID] = timestamp
            transitionLastEventTimes[transitionID] = timestamp
            return
        }
        if let previous = transitionLastEventTimes[transitionID] {
            metadata["elapsedSincePreviousMilliseconds"] = milliseconds(
                timestamp.timeIntervalSince(previous)
            )
        }
        transitionLastEventTimes[transitionID] = timestamp
        guard name == "transition.committed"
            || name == "transition.unchanged"
            || name == "transition.rejected"
            || name == "transition.deferred" else { return }
        if let started = transitionStartTimes.removeValue(forKey: transitionID) {
            metadata["durationMilliseconds"] = milliseconds(
                timestamp.timeIntervalSince(started)
            )
        }
        transitionLastEventTimes.removeValue(forKey: transitionID)
    }

    private func milliseconds(_ interval: TimeInterval) -> String {
        String(format: "%.3f", max(0, interval) * 1_000)
    }

    private func pruneTransitionTiming() {
        let retainedTransitionIDs = Set(
            entries.compactMap { $0.metadata["transitionID"] }
        )
        transitionStartTimes = transitionStartTimes.filter {
            retainedTransitionIDs.contains($0.key)
        }
        transitionLastEventTimes = transitionLastEventTimes.filter {
            retainedTransitionIDs.contains($0.key)
        }
    }
}
