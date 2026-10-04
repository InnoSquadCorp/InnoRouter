import InnoRouterCore

/// Runtime request intent carried independently of the resulting navigation
/// value. This metadata is neither a public command nor a serializable grant.
@MainActor
package final class RouterRequestAuthorization<R: Route>: Sendable {
    package let matchedRoutes: [R]
    package let configuration: RouterAuthorizationConfiguration<R>?
    /// Route intent associated with a denied decision, never an authorization grant.
    package var deniedRoute: R?

    package init(matchedRoutes: [R] = [], configuration: RouterAuthorizationConfiguration<R>? = nil) {
        self.matchedRoutes = matchedRoutes
        self.configuration = configuration
    }
}
