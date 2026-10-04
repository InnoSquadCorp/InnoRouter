import Foundation

/// Payload-free identity of a container root activated by a candidate state.
/// This is declaration metadata, never an authorization grant.
public struct RouterAuthorizationRootDescriptor: Hashable, Sendable, Codable {
    public let container: RouterScopePath
    public let style: RouterContainerStyle
    public let branch: RouterScopeID

    public init(container: RouterScopePath = .root, style: RouterContainerStyle, branch: RouterScopeID) {
        self.container = container
        self.style = style
        self.branch = branch
    }
}

/// Explicit declaration adapter for roots whose routes are not stored in paths.
/// Only descriptors activated by a candidate are read; inactive catalog entries
/// do not become authorization targets. This advanced adapter is provisional
/// pending consumer API review for the 7.0 development cycle.
public struct RouterAuthorizationCatalog<R: Route>: Sendable {
    private let roots: [RouterAuthorizationRootDescriptor: R]

    public init(roots: [RouterAuthorizationRootDescriptor: R] = [:]) {
        self.roots = roots
    }

    public func route(for descriptor: RouterAuthorizationRootDescriptor) -> R? {
        roots[descriptor]
    }
}

/// Extensible, payload-free authorization rejection. Unknown codes remain
/// representable without adding exhaustive enum cases to application switches.
public struct RouterAuthorizationFailure: Error, Hashable, Sendable {
    public struct Code: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let denied = Self(rawValue: "authorization.denied")
        public static let generationChanged = Self(rawValue: "authorization.generationChanged")
        public static let unresolvedRoot = Self(rawValue: "authorization.unresolvedRoot")
        public static let timedOut = Self(rawValue: "authorization.timedOut")
        public static let capacityExceeded = Self(rawValue: "authorization.capacityExceeded")
        public static let revalidationRequired = Self(rawValue: "authorization.revalidationRequired")
        public static let intentChanged = Self(rawValue: "authorization.intentChanged")
    }

    public let code: Code
    public let limit: Int?

    public init(code: Code, limit: Int? = nil) {
        self.code = code
        self.limit = limit
    }
}

/// App-owned authorization used again at actual Store application.
///
/// Increment `generation` on logout, account change, or permission revocation.
/// The library does not own a session, and cannot detect external changes when
/// that provider is omitted. The provider must be synchronous and side-effect
/// free. Its value and authorization results are never persisted.
///
/// `authorize` is one bounded asynchronous decision, not a wait for login UI.
/// Return false to retain a link as pending. Resume after login with the current
/// pipeline, which revalidates origin, declaration catalog, and authorization.
///
/// This callback admits protected navigation. Per-resource ownership and access
/// decisions remain app-owned policies and server checks; being signed in does
/// not by itself authorize every object named by a route.
public struct RouterAuthorizationConfiguration<R: Route>: Sendable {
    package let generation: (@MainActor @Sendable () -> UInt64)?
    package let requiresAuthorization: @Sendable (R) -> Bool
    package let authorize: @MainActor @Sendable () async -> Bool
    package let catalog: @MainActor @Sendable () -> RouterAuthorizationCatalog<R>

    public init(
        generation: (@MainActor @Sendable () -> UInt64)? = nil,
        requiresAuthorization: @escaping @Sendable (R) -> Bool,
        authorize: @escaping @MainActor @Sendable () async -> Bool,
        catalog: @escaping @MainActor @Sendable () -> RouterAuthorizationCatalog<R> = { .init() }
    ) {
        self.generation = generation
        self.requiresAuthorization = requiresAuthorization
        self.authorize = authorize
        self.catalog = catalog
    }

    /// The original match, every materialized route, and currently activated
    /// root declaration form one deduplicated union. Missing declaration
    /// metadata fails closed even if no materialized route requires auth.
    @MainActor
    package func targets(in state: RouterState<R>, matchedRoutes: [R]) throws -> [R] {
        var routes = matchedRoutes + state.authorizationRoutes
        let currentCatalog = catalog()
        for descriptor in state.authorizationRootDescriptors {
            guard let route = currentCatalog.route(for: descriptor) else {
                throw RouterAuthorizationFailure(code: .unresolvedRoot)
            }
            routes.append(route)
        }
        var seen: Set<R> = []
        return routes.filter { seen.insert($0).inserted }
    }
}

package extension RouterState {
    var authorizationRoutes: [R] {
        var routes: [R] = []
        func visit(_ node: RouterNode<R>) {
            switch node {
            case .stack(let stack):
                routes.append(contentsOf: stack.path)
                if let presentation = stack.presentation {
                    routes.append(presentation.route)
                    visit(presentation.node)
                }
            case .container(let container):
                for branch in container.branches { visit(branch.node) }
            }
        }
        visit(root)
        for window in windows {
            routes.append(window.route)
            visit(window.node)
        }
        if let immersiveSpace {
            routes.append(immersiveSpace.route)
            visit(immersiveSpace.node)
        }
        return routes
    }

    var authorizationRootDescriptors: [RouterAuthorizationRootDescriptor] {
        var descriptors: [RouterAuthorizationRootDescriptor] = []
        func visit(_ node: RouterNode<R>, at path: RouterScopePath, active: Bool) {
            switch node {
            case .stack(let stack):
                if let presentation = stack.presentation {
                    visit(presentation.node, at: path.appendingPresentation(presentation.id), active: active)
                }
            case .container(let container):
                for branch in container.branches {
                    // All split columns may be visible. A custom container with
                    // no selection declares all branches active; an inactive tab
                    // never activates descendants merely because it is stored.
                    let selected = container.style == .split
                        || container.selection == nil || container.selection == branch.id
                    let branchActive = active && selected
                    if branchActive {
                        descriptors.append(.init(container: path, style: container.style, branch: branch.id))
                    }
                    visit(branch.node, at: path.appending(branch.id), active: branchActive)
                }
            }
        }
        visit(root, at: .root, active: true)
        for window in windows { visit(window.node, at: .window(window.id), active: true) }
        if let immersiveSpace { visit(immersiveSpace.node, at: .immersiveSpace(immersiveSpace.id), active: true) }
        return descriptors
    }
}
