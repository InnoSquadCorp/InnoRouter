// MARK: - RouterTabRestorationTopology.swift
// InnoRouterSwiftUI - caller-supplied tab topology for restoration
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

/// Payload-free changes made while reconciling root tab structure.
public enum RouterTabRestorationChange: Hashable, Sendable, Codable {
    case insertedScope(RouterScopeID)
    case reorderedScopes([RouterScopeID])
    case selectionChanged(from: RouterScopeID?, to: RouterScopeID)
}

/// Structural failures in an explicit tab restoration topology.
public enum RouterTabRestorationError: Error, Hashable, Sendable {
    /// A topology must name at least one tab, because the first entry is the
    /// selection fallback.
    case emptyTopology
    /// Two entries named the same scope.
    case duplicateScopeID(RouterScopeID)
    /// The decoded snapshot's root is not a tabs container, so there is no tab
    /// topology to reconcile. The application migrates such a snapshot
    /// deliberately instead of having the router reshape it.
    case rootIsNotTabs
}

/// The ordered tab scopes an application renders right now.
///
/// Restoration is exact by default: ``RouterStore/restore(from:using:)``
/// applies what the snapshot says. A snapshot written before a tab was added
/// therefore decodes without that tab, and the tab stays unreachable.
///
/// Passing this value to a restore overload states the current topology as an
/// explicit input, so the router can add the missing scopes. It deliberately
/// carries scope identity only — no routes, presentations, badges, store, or
/// view — so reconciliation cannot smuggle payload into a restored state.
///
/// ```swift
/// let topology = try RouterTabRestorationTopology(of: AppRoute.self)
/// try await store.restore(from: data, using: codec, tabTopology: topology)
/// ```
///
/// The caller owns this value. Build it from the same catalog the host
/// renders, and replace it when that catalog changes.
public struct RouterTabRestorationTopology: Hashable, Sendable {
    /// Tab scopes in the order the application renders them.
    public let scopeIDs: [RouterScopeID]

    /// The scope a restored selection falls back to.
    ///
    /// A snapshot can select a tab this application no longer has. The first
    /// catalog entry is the only selection derivable from the caller's own
    /// input, so it is the fallback.
    public var fallbackSelection: RouterScopeID { scopeIDs[0] }

    public init(scopeIDs: [RouterScopeID]) throws {
        guard !scopeIDs.isEmpty else {
            throw RouterTabRestorationError.emptyTopology
        }
        if let duplicate = scopeIDs.first(where: { id in
            scopeIDs.filter { $0 == id }.count > 1
        }) {
            throw RouterTabRestorationError.duplicateScopeID(duplicate)
        }
        self.scopeIDs = scopeIDs
    }

    private init(validated scopeIDs: [RouterScopeID]) {
        self.scopeIDs = scopeIDs
    }

    /// Reads the topology from a validated catalog.
    public init<R: RouterTabRoute>(catalog: RouterTabCatalog<R>) {
        // `RouterTabCatalog` already rejects an empty catalog and duplicate
        // scope identifiers, so this cannot fail.
        self.init(validated: catalog.descriptors.map(\.tab.routerScopeID))
    }

    /// Reads the topology from a `@Router` generated catalog.
    public init<R: RouterTabRoute>(of routeType: R.Type) throws {
        _ = routeType
        self.init(catalog: try RouterTabCatalog(R.routerTabs))
    }
}

public extension RouterTabRestorationTopology {
    /// Returns `restored` with this topology's scopes present and selectable.
    ///
    /// The transformation is pure and total in its inputs: it reads nothing
    /// but the decoded state and this value.
    ///
    /// - A scope the snapshot already carries is kept exactly, including its
    ///   path, presentation, and badge.
    /// - A scope the snapshot lacks is created empty. No route, presentation,
    ///   or badge is invented for it.
    /// - A branch the snapshot carries that this topology does not name is an
    ///   orphan. It is preserved, after the current scopes and in its original
    ///   order, so a later catalog can still reach it.
    /// - A selection this topology no longer names becomes
    ///   ``fallbackSelection``.
    ///
    /// Windows and the immersive space are untouched.
    func reconciling<R: Route>(
        _ restored: RouterState<R>
    ) throws -> RouterState<R> {
        // This public function also accepts application-built mutable values,
        // not just states that have already passed through a snapshot codec.
        try restored.validate()
        guard case .container(let candidate) = restored.root,
              candidate.style == .tabs else {
            throw RouterTabRestorationError.rootIsNotTabs
        }
        try validateStackScopes(in: candidate)
        let named = Set(scopeIDs)
        let snapshotBranches = Dictionary(
            uniqueKeysWithValues: candidate.branches.map { ($0.id, $0) }
        )
        let current = scopeIDs.map { id in
            snapshotBranches[id] ?? RouterBranch<R>(id: id, node: .stack())
        }
        let orphans = candidate.branches.filter { !named.contains($0.id) }
        let selection = candidate.selection.flatMap {
            named.contains($0) ? $0 : nil
        } ?? fallbackSelection

        let reconciled = try RouterContainerState(
            style: .tabs,
            selection: selection,
            branches: current + orphans,
            badges: candidate.badges
        )
        return try RouterState(
            root: .container(reconciled),
            windows: restored.windows,
            immersiveSpace: restored.immersiveSpace
        )
    }

    internal func validateStackScopes<R: Route>(in container: RouterContainerState<R>) throws {
        let currentIDs = Set(scopeIDs)
        for branch in container.branches where currentIDs.contains(branch.id) {
            guard case .stack = branch.node else {
                throw RouterMutationError.expectedStack(.root.appending(branch.id))
            }
        }
    }

    internal func changes<R: Route>(
        from original: RouterState<R>, to reconciled: RouterState<R>
    ) -> [RouterTabRestorationChange] {
        guard case .container(let before) = original.root,
              case .container(let after) = reconciled.root else { return [] }
        let previousIDs = before.branches.map(\.id)
        let currentIDs = after.branches.map(\.id)
        let previousIDSet = Set(previousIDs)
        var changes = currentIDs.filter { !previousIDSet.contains($0) }
            .map(RouterTabRestorationChange.insertedScope)
        if previousIDs != currentIDs { changes.append(.reorderedScopes(currentIDs)) }
        if before.selection != after.selection, let selection = after.selection {
            changes.append(.selectionChanged(from: before.selection, to: selection))
        }
        return changes
    }
}
