import SwiftUI

import InnoRouterCore

/// A macro-first router host that owns the canonical ``RouterStore`` for a
/// ``DestinationRoute``.
///
/// `RouterHost` is the default self-contained surface for both push navigation
/// and modal presentation. When `R` conforms to `DeepLinkRoute`, admitted
/// incoming URLs enter the same typed action pipeline as local requests.
///
/// ```swift
/// @Router
/// enum AppRoute {
///     case settings
///
///     var destination: some View {
///         switch self {
///         case .settings: SettingsView()
///         }
///     }
/// }
///
/// struct AppRoot: View {
///     var body: some View {
///         RouterHost(AppRoute.self) {
///             HomeView()
///         }
///     }
/// }
/// ```
@MainActor
public struct RouterHost<R: DestinationRoute, Root: View>: View {
    @State private var ownedStore: RouterStore<R>
    private let suppliedStore: RouterStore<R>?
    private let root: () -> Root
    private let rootDeclarations: [RouterHostRootDeclaration<R>]
    private let presentations: RouterPresentationViewCatalog<R>
    private let linkHandling: RouterLinkHandling<R>?

    /// Creates a safe empty root-stack host with default resource limits.
    public init(
        _ routeType: R.Type,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) {
        _ = routeType
        self.root = root
        self.rootDeclarations = [.init(meaning: .declarationID("router.root"))]
        self.presentations = .stack
        self.linkHandling = linkHandling
        self.suppliedStore = nil
        self._ownedStore = State(initialValue: RouterStore<R>.makeDefaultHostedStack())
    }

    /// Creates a locally owned router for `routeType`.
    ///
    /// `initialPath` and `configuration` are captured when SwiftUI creates this
    /// host's state for the first time. Later input changes do not replace the
    /// existing store. Changing the opaque root's meaning requires a new
    /// `rootDeclarationID` and the owner's atomic `replaceHost` operation.
    public init(
        _ routeType: R.Type,
        initialPath: [R],
        configuration: RouterStoreConfiguration<R> = .init(),
        rootDeclarationID: String = "router.root",
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) throws {
        _ = routeType
        let rootDeclarations: [RouterHostRootDeclaration<R>] = [.init(meaning: .declarationID(rootDeclarationID))]
        var configuration = configuration
        if configuration.hostDescriptor == nil {
            configuration.hostDescriptor = RouterHostDescriptor(root: .stack, rootDeclarations: rootDeclarations)
        }
        let store = try RouterStore(initialPath: initialPath, configuration: configuration)
        try store.validateHostRenderer(shape: .stack, at: .root, rootDeclarations: rootDeclarations)
        try presentations.validate(for: store)
        self.root = root
        self.rootDeclarations = rootDeclarations
        self.presentations = presentations
        self.linkHandling = linkHandling
        self.suppliedStore = nil
        self._ownedStore = State(initialValue: store)
    }

    public init(
        _ routeType: R.Type,
        configuration: RouterStoreConfiguration<R>,
        rootDeclarationID: String = "router.root",
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) throws {
        try self.init(
            routeType, initialPath: [], configuration: configuration,
            rootDeclarationID: rootDeclarationID, presentations: presentations,
            linkHandling: linkHandling, root: root
        )
    }

    /// Hosts a store retained by an application boundary.
    ///
    /// For source compatibility this initializer does not throw. A missing or
    /// incompatible stack contract is exposed by `validationFailure` and
    /// visible recovery UI. Supply a configured Store to render its state.
    public init(
        store: RouterStore<R>,
        rootDeclarationID: String = "router.root",
        presentations: RouterPresentationViewCatalog<R> = .stack,
        linkHandling: RouterLinkHandling<R>? = nil,
        @ViewBuilder root: @escaping () -> Root
    ) {
        self.root = root
        self.rootDeclarations = [.init(meaning: .declarationID(rootDeclarationID))]
        self.presentations = presentations
        self.linkHandling = linkHandling
        self.suppliedStore = store
        self._ownedStore = State(initialValue: store)
    }

    /// A typed, payload-redacted failure for the Store's current contract.
    /// Reading this value never installs a contract or changes navigation state.
    public var validationFailure: RouterHostValidationFailure? {
        do {
            try store.validateHostRenderer(shape: .stack, at: .root, rootDeclarations: rootDeclarations)
            try presentations.validate(for: store)
            return nil
        } catch {
            return error
        }
    }

    public var body: some View {
        RouterValidatedHostSurface(store: store, shape: .stack, rootDeclarations: rootDeclarations, presentations: presentations, path: .root) { scope in
            RouterStoreStackSurface(
                scope: scope,
                destination: R.destination(for:),
                root: root
            )
            .routerAuthority(scope, for: R.self)
            .handleRouterPlans(
                for: R.self,
                scope: scope,
                handling: linkHandling
            ) { route, state in
                let target = try state.replacingNode(.stack(path: [route]), at: .root, resourceBudget: store.resourceBudget)
                return RouterPlan(state: target)
            }
        }
    }

    private var store: RouterStore<R> { suppliedStore ?? ownedStore }
}
