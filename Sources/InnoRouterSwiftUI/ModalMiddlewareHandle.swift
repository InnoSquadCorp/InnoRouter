import Foundation

/// Opaque identifier for a registered modal middleware instance.
///
/// Mirrors `NavigationMiddlewareHandle`: handles are stable across registry
/// mutations (`replace`/`move` preserve identity) and are the key consumers
/// use to remove/replace/move a specific registration later.
public struct ModalMiddlewareHandle: Hashable, Sendable {
    private let rawValue: UUID

    /// Creates a framework-owned middleware handle.
    internal init() {
        self.rawValue = UUID()
    }

    var logValue: String {
        rawValue.uuidString
    }
}
