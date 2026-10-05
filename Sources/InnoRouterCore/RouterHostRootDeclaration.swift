// InnoRouterCore - frozen semantic meanings for host roots

/// The semantic identity of one declared root view.
///
/// A native route root records its exact value. An arbitrary View closure cannot
/// be inspected for semantic equality, so manual/custom roots use a stable,
/// application-owned declaration ID instead. Keep that ID unchanged for label,
/// localization and visual-only edits; change it when the root's meaning or
/// navigation responsibility changes, then replace the owning Store's complete
/// host descriptor through its explicit replacement operation.
///
/// These values are never hashed or stringified by host validation. Route
/// equality runs only after complete resource and structure admission. Like all
/// Route callbacks, application-defined equality must be pure and terminating.
public enum RouterHostRootMeaning<R: Route>: Sendable {
    case route(R)
    case declarationID(String)
}

/// One frozen root meaning at a branch-only path relative to a host declaration.
///
/// The empty path names that host's root. Every nonempty path must name a branch
/// explicitly rendered by its declared shape; dormant/orphan branches cannot
/// receive a root meaning. Presentation and scene instances use the relative
/// roots on their own frozen catalog entry, not candidate-derived declarations.
/// Labels and other presentation-only metadata are intentionally absent.
public struct RouterHostRootDeclaration<R: Route>: Sendable {
    public let path: [RouterScopeID]
    public let meaning: RouterHostRootMeaning<R>

    public init(path: [RouterScopeID] = [], meaning: RouterHostRootMeaning<R>) {
        self.path = path
        self.meaning = meaning
    }
}

package extension RouterHostRootMeaning {
    func matches(_ other: Self) -> Bool {
        switch (self, other) {
        case (.route(let lhs), .route(let rhs)): lhs == rhs
        case (.declarationID(let lhs), .declarationID(let rhs)): lhs == rhs
        default: false
        }
    }
}
