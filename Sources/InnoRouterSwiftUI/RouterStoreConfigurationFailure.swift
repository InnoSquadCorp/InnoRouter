import InnoRouterCore

/// Extensible, payload-safe failure for invalid Store configuration input.
/// Library field names identify settings only and contain no route payloads.
public struct RouterStoreConfigurationFailure: Error, Hashable, Sendable, CustomStringConvertible {
    public struct Code: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let invalidValue = Self(rawValue: "innorouter.store.configuration.invalidValue")
    }

    public let code: Code
    public let field: String
    public init(code: Code = .invalidValue, field: String) {
        self.code = code
        self.field = field
    }
    public var description: String { code.rawValue }
}

extension RouterStoreConfiguration {
    /// Check raw compatibility fields before deriving the canonical budget.
    /// Zero means no capacity or an immediate deadline; nil explicitly opts out.
    func validate() throws {
        let counts: [(String, Int?)] = [
            ("maximumPendingRequestCount", maximumPendingRequestCount),
            ("deferrals.maximumPendingCount", deferrals.maximumPendingCount),
            ("maximumActivePolicyOperationCount", maximumActivePolicyOperationCount),
            ("maximumActiveRestorationOperationCount", maximumActiveRestorationOperationCount),
        ]
        for (field, value) in counts {
            if let value, value < 0 { throw RouterStoreConfigurationFailure(field: field) }
        }
        if let policyTimeout, policyTimeout < .zero { throw RouterStoreConfigurationFailure(field: "policyTimeout") }
        if let timeToLive = deferrals.timeToLive, timeToLive < .zero {
            throw RouterStoreConfigurationFailure(field: "deferrals.timeToLive")
        }
        switch eventBufferingPolicy {
        case .bufferingNewest(let count), .bufferingOldest(let count):
            if count < 0 { throw RouterStoreConfigurationFailure(field: "eventBufferingPolicy") }
        case .unbounded: break
        }
        try resourceBudget.validateConfiguration()
    }
}
