/// Stable identity for export failures. Preserve a fallback for unknown future
/// codes rather than exhaustively switching over known values.
public struct RouterInspectorExportFailureCode: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let encodedDataTooLarge = Self(rawValue: "innorouter.inspector.encodedDataTooLarge")
}

/// Payload-free export measurements; no captured entry or encoded data is kept.
public struct RouterInspectorExportFailureDetails: Hashable, Sendable, Codable {
    public let actualByteCount: Int?
    public let maximumByteCount: Int?

    public init(actualByteCount: Int? = nil, maximumByteCount: Int? = nil) {
        self.actualByteCount = actualByteCount
        self.maximumByteCount = maximumByteCount
    }
}

/// An extensible, payload-free export failure. Library-created failures retain
/// only the code and byte counts; descriptions print the code alone.
/// Errors thrown by a caller's JSONEncoder are propagated without wrapping.
public struct RouterInspectorExportFailure: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public let code: RouterInspectorExportFailureCode
    public let details: RouterInspectorExportFailureDetails

    public init(
        code: RouterInspectorExportFailureCode,
        details: RouterInspectorExportFailureDetails = .init()
    ) {
        self.code = code
        self.details = details
    }

    public var description: String { code.rawValue }

    public static func encodedDataTooLarge(actualByteCount: Int, maximumByteCount: Int) -> Self {
        Self(code: .encodedDataTooLarge, details: .init(
            actualByteCount: actualByteCount, maximumByteCount: maximumByteCount
        ))
    }
}
