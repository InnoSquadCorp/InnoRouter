// InnoRouterCore - extensible, payload-free legacy snapshot preflight failures

/// JSON-complexity diagnostics nested in ``RouterSnapshotError/preflight(_:)``.
/// Library-created details contain only stage, schema version and numeric limits;
/// route payloads, JSON keys and migration messages are never captured here.
public struct RouterSnapshotPreflightError: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    /// Unknown future codes remain representable without new enum cases.
    public struct Code: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let invalidLimit = Self(rawValue: "innorouter.snapshot.invalidLimit")
        public static let limitExceeded = Self(rawValue: "innorouter.snapshot.limitExceeded")
        public static let duplicateJSONKey = Self(rawValue: "innorouter.snapshot.duplicateJSONKey")
    }

    public struct Details: Hashable, Sendable, Codable {
        public let stage: String?
        public let version: Int?
        public let field: String?
        public let value: Int?
        public let actual: Int?
        public let maximum: Int?

        public init(
            stage: String? = nil, version: Int? = nil, field: String? = nil,
            value: Int? = nil, actual: Int? = nil, maximum: Int? = nil
        ) {
            self.stage = stage
            self.version = version
            self.field = field
            self.value = value
            self.actual = actual
            self.maximum = maximum
        }
    }

    public let code: Code
    public let details: Details

    public init(code: Code, details: Details = .init()) {
        self.code = code
        self.details = details
    }

    public var description: String { code.rawValue }
}
