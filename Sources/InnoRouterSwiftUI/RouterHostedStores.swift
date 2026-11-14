// MARK: - RouterHostedStores.swift
// InnoRouterSwiftUI - Stores already declared for the default hosts
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension RouterTabCatalog where R: DestinationRoute {
    /// Builds the tab container, declares this catalog as the host, and
    /// creates the Store. Shared by ``RouterTabHost`` and the public factory.
    @MainActor
    func makeHostedStore(
        initial: R.Tab,
        badges: [R.Tab: Int],
        orphanPolicy: RouterHostOrphanPolicy = .reject,
        configuration: RouterStoreConfiguration<R>
    ) throws -> RouterStore<R> {
        guard descriptor(for: initial) != nil else {
            throw RouterTabCatalogError.initialTabNotInCatalog
        }
        var configuration = configuration
        if configuration.hostDescriptor == nil {
            configuration.hostDescriptor = hostDescriptor(orphanPolicy: orphanPolicy)
        }
        let container = try RouterContainerState(
            style: .tabs,
            selection: initial.routerScopeID,
            branches: descriptors.map { RouterBranch<R>(id: $0.tab.routerScopeID) },
            badges: Dictionary<RouterScopeID, Int>(uniqueKeysWithValues: badges.compactMap { tab, count in
                guard descriptor(for: tab) != nil, count > 0 else { return nil }
                return (tab.routerScopeID, count)
            })
        )
        let state = try RouterStateDraft<R>(root: .container(container))
            .build(resourceBudget: configuration.resourceBudget)
        return try R.makeRouterStore(initialState: state, configuration: configuration)
    }
}

public extension DestinationRoute {
    /// Creates an empty root-stack Store that already declares the default
    /// stack host, so it can be handed to `RouterHost(store:)` as is.
    ///
    /// Use it when something besides the host needs the Store, such as a
    /// ``RouterRestorationDriver``. ``makeRouterStore()`` creates a Store with
    /// no host declaration, which a supplied-store host reports as a
    /// validation failure.
    ///
    /// The declaration matches `RouterHost(store:)` with its default
    /// `rootDeclarationID` (`"router.root"`) and stack presentations. A host
    /// that passes another root declaration ID needs a Store declared for it,
    /// through ``makeRouterHostStore(configuration:)`` with a matching
    /// `hostDescriptor`. The result is a stack Store on every route type; a
    /// tab router's Store comes from
    /// `makeRouterTabHostStore(initial:badges:orphanPolicy:configuration:)`.
    @MainActor
    static func makeRouterHostStore() -> RouterStore<Self> {
        RouterStore<Self>.makeDefaultHostedStack()
    }

    /// Creates an empty root-stack Store for `RouterHost(store:)` with the
    /// given configuration.
    ///
    /// When `configuration.hostDescriptor` is `nil`, the Store declares the
    /// default stack host, as ``makeRouterHostStore()`` does. A descriptor the
    /// configuration already carries is kept unchanged.
    ///
    /// - Throws: The errors of `RouterStore(configuration:)`, for example a
    ///   `RouterResourceLimitFailure` for an invalid budget.
    @MainActor
    static func makeRouterHostStore(
        configuration: RouterStoreConfiguration<Self>
    ) throws -> RouterStore<Self> {
        var configuration = configuration
        if configuration.hostDescriptor == nil {
            configuration.hostDescriptor = .init(
                root: .stack, rootDeclarations: [.init(path: [], meaning: .declarationID("router.root"))]
            )
        }
        return try RouterStore(configuration: configuration)
    }
}

public extension DestinationRoute where Self: RouterTabRoute {
    /// Creates a Store that holds this router's declared tabs and already
    /// declares them as its host, so it can be handed to
    /// `RouterTabHost(store:orphanPolicy:)` as is.
    ///
    /// - Parameters:
    ///   - initial: The selected tab. Defaults to the first declared tab.
    ///   - badges: Initial badge counts. Zero and negative counts are ignored.
    ///   - orphanPolicy: The host's orphan policy. Pass `.preserveDormant`,
    ///     and the same value to `RouterTabHost(store:orphanPolicy:)`, when a
    ///     restored snapshot may still hold a tab the catalog no longer
    ///     declares.
    ///   - configuration: The Store configuration. A `hostDescriptor` it
    ///     already carries is kept unchanged, and `orphanPolicy` is then not
    ///     used.
    /// - Throws: A `RouterTabCatalogError` when the declared tabs are not a
    ///   valid catalog or `initial` is not one of them, and the errors of
    ///   `RouterStore(initialState:configuration:)`.
    @MainActor
    static func makeRouterTabHostStore(
        initial: Tab? = nil,
        badges: [Tab: Int] = [:],
        orphanPolicy: RouterHostOrphanPolicy = .reject,
        configuration: RouterStoreConfiguration<Self> = .init()
    ) throws -> RouterStore<Self> {
        let catalog = try RouterTabCatalog(routerTabs)
        guard let initial = initial ?? catalog.descriptors.first?.tab else {
            throw RouterTabCatalogError.empty
        }
        return try catalog.makeHostedStore(
            initial: initial, badges: badges, orphanPolicy: orphanPolicy, configuration: configuration
        )
    }
}
