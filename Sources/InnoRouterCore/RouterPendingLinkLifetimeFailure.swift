/// Payload-free durable-intent lifetime rejection. This is separate from both
/// authorization and live topology incarnation. Unknown codes stay representable.
public struct RouterPendingLinkLifetimeFailure: Error, Hashable, Sendable {
    public struct Code: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let expired = Self(rawValue: "pendingLink.expired")
        public static let clockReversed = Self(rawValue: "pendingLink.clockReversed")
        public static let invalidTimestamp = Self(rawValue: "pendingLink.invalidTimestamp")
        public static let missingOriginTimestamp = Self(rawValue: "pendingLink.missingOriginTimestamp")
    }
    public let code: Code
    public init(code: Code) { self.code = code }
}
