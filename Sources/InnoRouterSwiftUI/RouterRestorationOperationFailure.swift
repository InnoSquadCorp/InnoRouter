// InnoRouterSwiftUI - extensible, payload-free restoration admission diagnostics

/// Stable identity for restoration operation failures. Preserve a fallback for
/// unknown future codes rather than exhaustively switching over known values.
public struct RouterRestorationOperationFailureCode: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let capacityExceeded = Self(rawValue: "innorouter.restoration.operationCapacityExceeded")
}

/// Typed details describe actual planner operations, including those still
/// running after their logical restoration timed out or was cancelled.
public struct RouterRestorationOperationFailureDetails: Hashable, Sendable, Codable {
    public let maximumCount: Int?
    public let activeCount: Int?

    public init(maximumCount: Int? = nil, activeCount: Int? = nil) {
        self.maximumCount = maximumCount
        self.activeCount = activeCount
    }
}

/// Extensible admission failure. Library-created values retain no route payload,
/// validator reason or application error text; descriptions print the code only.
public struct RouterRestorationOperationFailure: Error, Hashable, Sendable, Codable, CustomStringConvertible {
    public let code: RouterRestorationOperationFailureCode
    public let details: RouterRestorationOperationFailureDetails

    public init(
        code: RouterRestorationOperationFailureCode,
        details: RouterRestorationOperationFailureDetails = .init()
    ) {
        self.code = code
        self.details = details
    }

    public var description: String { code.rawValue }

    public static func capacityExceeded(maximumCount: Int, activeCount: Int) -> Self {
        Self(code: .capacityExceeded, details: .init(maximumCount: maximumCount, activeCount: activeCount))
    }
}
