import Foundation

/// Opaque identifier for a registered navigation middleware instance.
public struct NavigationMiddlewareHandle: Hashable, Sendable {
    private let rawValue: UUID

    /// Creates a framework-owned middleware handle.
    internal init() {
        self.rawValue = UUID()
    }

    var logValue: String {
        rawValue.uuidString
    }
}
