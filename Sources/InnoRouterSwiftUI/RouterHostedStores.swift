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
        configuration: RouterStoreConfiguration<R>
    ) throws -> RouterStore<R> {
        guard descriptor(for: initial) != nil else {
            throw RouterTabCatalogError.initialTabNotInCatalog
        }
        var configuration = configuration
        if configuration.hostDescriptor == nil {
            configuration.hostDescriptor = hostDescriptor()
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
    /// validation failure. The result is a stack Store on every route type:
    /// a tab router's Store for `RouterTabHost(store:)` comes from
    /// `makeHostedTabRouterStore(initial:badges:configuration:)`.
    @MainActor
    static func makeHostedRouterStore() -> RouterStore<Self> {
        RouterStore<Self>.makeDefaultHostedStack()
    }
}

public extension DestinationRoute where Self: RouterTabRoute {
    /// Creates a Store that holds this router's declared tabs and already
    /// declares them as its host, so it can be handed to
    /// `RouterTabHost(store:)` as is.
    ///
    /// `initial` defaults to the first declared tab. A `configuration` that
    /// carries its own host descriptor keeps it.
    @MainActor
    static func makeHostedTabRouterStore(
        initial: Tab? = nil,
        badges: [Tab: Int] = [:],
        configuration: RouterStoreConfiguration<Self> = .init()
    ) throws -> RouterStore<Self> {
        let catalog = try RouterTabCatalog(routerTabs)
        guard let initial = initial ?? catalog.descriptors.first?.tab else {
            throw RouterTabCatalogError.empty
        }
        return try catalog.makeHostedStore(initial: initial, badges: badges, configuration: configuration)
    }
}
