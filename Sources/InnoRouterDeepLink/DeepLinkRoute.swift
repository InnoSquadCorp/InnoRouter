import Foundation

import InnoRouterCore

/// A route type that can resolve an admitted URL into one typed destination.
///
/// `DeepLinkRoute` is the small runtime capability used by macro-first hosts.
/// Implementations must fail closed by returning `nil` when the URL origin or
/// path is not explicitly supported. Keep authentication, pending replay, and
/// multi-step navigation in ``DeepLinkPipeline`` or ``FlowDeepLinkPipeline``;
/// this protocol intentionally resolves only one route value.
///
/// The resolver is synchronous and carries no session authority, so conforming
/// route enums remain immutable `Sendable` values.
public protocol DeepLinkRoute: Route {
    /// Resolves `url` into one route, or returns `nil` when it is rejected or
    /// does not match this route type.
    static func resolveDeepLink(_ url: URL) -> Self?
}
