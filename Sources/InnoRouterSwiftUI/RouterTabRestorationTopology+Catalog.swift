// MARK: - RouterTabRestorationTopology+Catalog.swift
// InnoRouterSwiftUI - native catalog adapter for restoration topology
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

public extension RouterTabRestorationTopology {
    /// Reads the topology from a validated catalog.
    init<R: RouterTabRoute>(catalog: RouterTabCatalog<R>) {
        // `RouterTabCatalog` already rejects an empty catalog and duplicate
        // scope identifiers, so this cannot fail.
        self.init(validated: catalog.descriptors.map(\.tab.routerScopeID))
    }

    /// Reads the topology from a `@Router` generated catalog.
    init<R: RouterTabRoute>(of routeType: R.Type) throws {
        _ = routeType
        self.init(catalog: try RouterTabCatalog(R.routerTabs))
    }
}
