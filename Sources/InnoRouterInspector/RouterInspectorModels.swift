import Foundation

import InnoRouterCore

func routerInspectorLocalized(_ key: String, locale: Locale? = nil) -> String {
    // SwiftPM 6.3 copies catalogs instead of compiling them into .lproj files.
    if let catalog = RouterInspectorLocalization.sourceCatalog {
        return catalog.localized(key, preferredLanguages: locale.map { [$0.identifier] } ?? Locale.preferredLanguages)
    }
    guard let locale else {
        return String(localized: String.LocalizationValue(key), bundle: .module)
    }
    // String(localized:locale:) controls formatting but does not select a
    // different .lproj when the process language and SwiftUI locale disagree.
    let language = Bundle.preferredLocalizations(
        from: Array(Set(RouterInspectorLocalization.bundles.keys).union(["en"])).sorted(),
        forPreferences: [locale.identifier, "en"]
    ).first ?? "en"
    // Catalog keys are English source text; Xcode may omit en.lproj when
    // there are no explicit source-language overrides.
    guard language != "en" else { return key }
    let bundle = RouterInspectorLocalization.bundles[language] ?? .module
    return String(localized: String.LocalizationValue(key), bundle: bundle, locale: locale)
}

enum RouterInspectorLocalization {
    // Cache immutable resources only, never the selected language or rendered state.
    static let sourceCatalog: RouterInspectorSourceCatalog? = {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? RouterInspectorSourceCatalog(data: data)
    }()

    static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        Bundle.module.localizations.compactMap { language in
            guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        }
    )
}

/// Router subsystem represented by one inspector entry.
public enum RouterInspectorDomain: String, Sendable, Codable, CaseIterable, Identifiable {
    case router
    case application

    public var id: Self { self }
}

/// High-level result classification that does not expose route payloads.
public enum RouterInspectorOutcome: String, Sendable, Codable {
    case accepted
    case rejected
    case informational
}

public enum RouterInspectorExecutionStatus: String, Hashable, Sendable, Codable {
    case applied
    case unchanged
    case deferred
    case rejected
    case cancelled
    case unresolved
}

/// A privacy-safe value produced by an event formatter.
public struct RouterInspectorEventDescription: Sendable, Equatable {
    public var name: String
    public var outcome: RouterInspectorOutcome
    public var metadata: [String: String]
    public var state: RouterInspectorStateTree?
    public var diff: RouterInspectorStateDiff?
    public var replay: RouterInspectorReplayPreview?

    public init(
        name: String,
        outcome: RouterInspectorOutcome = .informational,
        metadata: [String: String] = [:],
        state: RouterInspectorStateTree? = nil,
        diff: RouterInspectorStateDiff? = nil,
        replay: RouterInspectorReplayPreview? = nil
    ) {
        self.name = name
        self.outcome = outcome
        self.metadata = metadata
        self.state = state
        self.diff = diff
        self.replay = replay
    }
}

/// One value-only row in the inspector timeline.
public struct RouterInspectorEntry: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let domain: RouterInspectorDomain
    public let name: String
    public let outcome: RouterInspectorOutcome
    public let metadata: [String: String]
    public let state: RouterInspectorStateTree?
    public let diff: RouterInspectorStateDiff?
    public let replay: RouterInspectorReplayPreview?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: RouterInspectorDomain,
        name: String,
        outcome: RouterInspectorOutcome,
        metadata: [String: String] = [:],
        state: RouterInspectorStateTree? = nil,
        diff: RouterInspectorStateDiff? = nil,
        replay: RouterInspectorReplayPreview? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.name = name
        self.outcome = outcome
        self.metadata = metadata
        self.state = state
        self.diff = diff
        self.replay = replay
    }
}

/// A serializable point-in-time inspector export.
public struct RouterInspectorSnapshot: Sendable, Equatable, Codable {
    public let generatedAt: Date
    public let entries: [RouterInspectorEntry]
    public let bookmarkedEntryIDs: Set<RouterInspectorEntry.ID>

    public init(
        generatedAt: Date = Date(),
        entries: [RouterInspectorEntry],
        bookmarkedEntryIDs: Set<RouterInspectorEntry.ID> = []
    ) {
        self.generatedAt = generatedAt
        self.entries = entries
        self.bookmarkedEntryIDs = bookmarkedEntryIDs.intersection(entries.map(\.id))
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt
        case entries
        case bookmarkedEntryIDs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        entries = try container.decode([RouterInspectorEntry].self, forKey: .entries)
        let bookmarks = try container.decodeIfPresent(
            Set<RouterInspectorEntry.ID>.self,
            forKey: .bookmarkedEntryIDs
        ) ?? []
        bookmarkedEntryIDs = bookmarks.intersection(entries.map(\.id))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(entries, forKey: .entries)
        if !bookmarkedEntryIDs.isEmpty {
            try container.encode(
                bookmarkedEntryIDs.sorted { $0.uuidString < $1.uuidString },
                forKey: .bookmarkedEntryIDs
            )
        }
    }
}

/// A support-ready, payload-redacted Inspector export with environment
/// identity kept separate from the captured timeline.
public struct RouterInspectorDiagnosticBundle: Sendable, Equatable, Codable {
    public let formatVersion: Int
    public let frameworkVersion: String
    public let platform: RouterPlatform
    public let snapshot: RouterInspectorSnapshot

    public init(
        frameworkVersion: String = InnoRouterVersion.current,
        platform: RouterPlatform,
        snapshot: RouterInspectorSnapshot
    ) {
        self.formatVersion = 1
        self.frameworkVersion = frameworkVersion
        self.platform = platform
        self.snapshot = snapshot
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported Inspector diagnostic bundle format \(version)."
            )
        }
        formatVersion = version
        frameworkVersion = try container.decode(String.self, forKey: .frameworkVersion)
        platform = try container.decode(RouterPlatform.self, forKey: .platform)
        snapshot = try container.decode(RouterInspectorSnapshot.self, forKey: .snapshot)
    }
}

/// How an imported inspector snapshot changes a recorder timeline.
public enum RouterInspectorImportPolicy: Sendable, Hashable {
    case replace
    case append
}

/// Resource limits applied before an imported session is decoded.
public struct RouterInspectorImportLimits: Sendable, Hashable {
    public var maximumEncodedByteCount: Int
    public var maximumEntryCount: Int

    public init(
        maximumEncodedByteCount: Int = 8 * 1_024 * 1_024,
        maximumEntryCount: Int = 5_000
    ) {
        self.maximumEncodedByteCount = max(1, maximumEncodedByteCount)
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    public static let `default` = Self()
}

/// Typed failures surfaced before imported entries reach a timeline.
public enum RouterInspectorImportError: Error, Sendable, Hashable {
    case duplicateEntryID(UUID)
    case encodedDataTooLarge(actualByteCount: Int, maximumByteCount: Int)
    case tooManyEntries(actualCount: Int, maximumCount: Int)
    case malformedSnapshotEnvelope
}

/// Converts one typed router event into an inspector-safe description.
///
/// Default store attachments use payload-redacted formatters. Supplying a
/// custom formatter is the explicit opt-in point for app-specific details.
public struct RouterInspectorFormatter<Event: Sendable>: Sendable {
    private let format: @Sendable (Event) -> RouterInspectorEventDescription

    public init(
        _ format: @escaping @Sendable (Event) -> RouterInspectorEventDescription
    ) {
        self.format = format
    }

    public func callAsFunction(_ event: Event) -> RouterInspectorEventDescription {
        format(event)
    }
}

/// Lifetime handle for one asynchronous inspector subscription.
public final class RouterInspectorSubscription: Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    public func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}
