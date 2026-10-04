/// Extensible identity for graph snapshot diagnostics. Unknown future codes are
/// preserved; application switches must include a fallback.
public struct RouterGraphSnapshotErrorCode: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let invalidLimit = Self(rawValue: "innorouter.snapshot.graph.invalidLimit")
    public static let limitExceeded = Self(rawValue: "innorouter.snapshot.graph.limitExceeded")
    public static let malformedJSON = Self(rawValue: "innorouter.snapshot.graph.malformedJSON")
    public static let duplicateJSONKey = Self(rawValue: "innorouter.snapshot.graph.duplicateJSONKey")
    public static let invalidEnvelope = Self(rawValue: "innorouter.snapshot.graph.invalidEnvelope")
    public static let unsupportedFormat = Self(rawValue: "innorouter.snapshot.graph.unsupportedFormat")
    public static let invalidSchema = Self(rawValue: "innorouter.snapshot.graph.invalidSchema")
    public static let schemaMismatch = Self(rawValue: "innorouter.snapshot.graph.schemaMismatch")
    public static let futureSchema = Self(rawValue: "innorouter.snapshot.graph.futureSchema")
    public static let invalidMigration = Self(rawValue: "innorouter.snapshot.graph.invalidMigration")
    public static let duplicateMigration = Self(rawValue: "innorouter.snapshot.graph.duplicateMigration")
    public static let missingMigration = Self(rawValue: "innorouter.snapshot.graph.missingMigration")
    public static let migrationFailed = Self(rawValue: "innorouter.snapshot.graph.migrationFailed")
    public static let invalidGraph = Self(rawValue: "innorouter.snapshot.graph.invalidGraph")
    public static let duplicateRecord = Self(rawValue: "innorouter.snapshot.graph.duplicateRecord")
    public static let danglingReference = Self(rawValue: "innorouter.snapshot.graph.danglingReference")
    public static let multipleOwners = Self(rawValue: "innorouter.snapshot.graph.multipleOwners")
    public static let orphanRecord = Self(rawValue: "innorouter.snapshot.graph.orphanRecord")
    public static let cycle = Self(rawValue: "innorouter.snapshot.graph.cycle")
    public static let unknownRouteKey = Self(rawValue: "innorouter.snapshot.graph.unknownRouteKey")
    public static let unsupportedRoutePayloadVersion = Self(rawValue: "innorouter.snapshot.graph.unsupportedRoutePayloadVersion")
    public static let routeEncodingFailed = Self(rawValue: "innorouter.snapshot.graph.routeEncodingFailed")
    public static let routeDecodingFailed = Self(rawValue: "innorouter.snapshot.graph.routeDecodingFailed")
    public static let encodingFailed = Self(rawValue: "innorouter.snapshot.graph.encodingFailed")
    public static let invalidState = Self(rawValue: "innorouter.snapshot.graph.invalidState")
}

/// Library-created details contain numeric limits/versions and structural field
/// names, never route payload, app codec errors, or original URL text.
public struct RouterGraphSnapshotErrorDetails: Hashable, Sendable, Codable {
    public let name: String?
    public let kind: String?
    public let value: Int?
    public let actual: Int?
    public let maximum: Int?
    public let snapshot: Int?
    public let current: Int?
    public let from: Int?
    public let to: Int?
    public let version: Int?

    public init(
        name: String? = nil,
        kind: String? = nil,
        value: Int? = nil,
        actual: Int? = nil,
        maximum: Int? = nil,
        snapshot: Int? = nil,
        current: Int? = nil,
        from: Int? = nil,
        to: Int? = nil,
        version: Int? = nil
    ) {
        self.name = name
        self.kind = kind
        self.value = value
        self.actual = actual
        self.maximum = maximum
        self.snapshot = snapshot
        self.current = current
        self.from = from
        self.to = to
        self.version = version
    }
}

/// A forward-compatible graph failure value. The description emits only its
/// code; opt into typed details when diagnosing trusted structural metadata.
public struct RouterGraphSnapshotError: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public let code: RouterGraphSnapshotErrorCode
    public let details: RouterGraphSnapshotErrorDetails

    public init(code: RouterGraphSnapshotErrorCode, details: RouterGraphSnapshotErrorDetails = .init()) {
        self.code = code
        self.details = details
    }

    public var description: String { code.rawValue }

    public static func invalidLimit(name: String, value: Int) -> Self {
        Self(code: .invalidLimit, details: .init(name: name, value: value))
    }
    public static func limitExceeded(name: String, actual: Int, maximum: Int) -> Self {
        Self(code: .limitExceeded, details: .init(name: name, actual: actual, maximum: maximum))
    }
    public static let malformedJSON = Self(code: .malformedJSON)
    public static let duplicateJSONKey = Self(code: .duplicateJSONKey)
    public static let invalidEnvelope = Self(code: .invalidEnvelope)
    public static func unsupportedFormat(snapshot: Int, current: Int) -> Self {
        Self(code: .unsupportedFormat, details: .init(snapshot: snapshot, current: current))
    }
    public static let invalidSchema = Self(code: .invalidSchema)
    public static let schemaMismatch = Self(code: .schemaMismatch)
    public static func futureSchema(snapshot: Int, current: Int) -> Self {
        Self(code: .futureSchema, details: .init(snapshot: snapshot, current: current))
    }
    public static func invalidMigration(from: Int, to: Int) -> Self {
        Self(code: .invalidMigration, details: .init(from: from, to: to))
    }
    public static func duplicateMigration(_ version: Int) -> Self {
        Self(code: .duplicateMigration, details: .init(version: version))
    }
    public static func missingMigration(from: Int, current: Int) -> Self {
        Self(code: .missingMigration, details: .init(current: current, from: from))
    }
    public static func migrationFailed(from: Int, to: Int) -> Self {
        Self(code: .migrationFailed, details: .init(from: from, to: to))
    }
    public static let invalidGraph = Self(code: .invalidGraph)
    public static func duplicateRecord(kind: String) -> Self {
        Self(code: .duplicateRecord, details: .init(kind: kind))
    }
    public static func danglingReference(kind: String) -> Self {
        Self(code: .danglingReference, details: .init(kind: kind))
    }
    public static func multipleOwners(kind: String) -> Self {
        Self(code: .multipleOwners, details: .init(kind: kind))
    }
    public static func orphanRecord(kind: String) -> Self {
        Self(code: .orphanRecord, details: .init(kind: kind))
    }
    public static let cycle = Self(code: .cycle)
    public static let unknownRouteKey = Self(code: .unknownRouteKey)
    public static let unsupportedRoutePayloadVersion = Self(code: .unsupportedRoutePayloadVersion)
    public static let routeEncodingFailed = Self(code: .routeEncodingFailed)
    public static let routeDecodingFailed = Self(code: .routeDecodingFailed)
    public static let encodingFailed = Self(code: .encodingFailed)
    public static let invalidState = Self(code: .invalidState)
}
