// MARK: - RouterTabRestoration.swift
// InnoRouterSwiftUI - restoration-time tab topology reconciliation
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension RouterStore {
    /// Reconciles a decoded tab tree with the topology captured when this store
    /// was created. Restoration may contain branches written by an older app
    /// version, but a host must still be able to select and navigate every tab
    /// in the current app.
    ///
    /// This is deliberately scoped to restoration. Ordinary `RouterPlan`
    /// application remains exact, and the reconciled value still enters the
    /// normal policy and atomic commit pipeline as one plan.
    func prepareRestoredState(_ restored: RouterState<R>) throws -> RouterState<R> {
        guard let baseline = restorationTabBaseline else { return restored }
        guard case .container(let candidate) = restored.root,
              candidate.style == .tabs else {
            throw RouterMutationError.incompatibleNavigationTopology(.root)
        }

        let currentIDs = baseline.branches.map(\.id)
        let currentIDSet = Set(currentIDs)
        let restoredByID = Dictionary(
            uniqueKeysWithValues: candidate.branches.map { ($0.id, $0) }
        )

        let currentBranches = try baseline.branches.map { baselineBranch in
            guard let restoredBranch = restoredByID[baselineBranch.id] else {
                return baselineBranch
            }
            guard Self.hasCompatibleRestorationTopology(
                restoredBranch.node,
                baselineBranch.node
            ) else {
                throw RouterMutationError.incompatibleNavigationTopology(
                    .root.appending(baselineBranch.id)
                )
            }
            return restoredBranch
        }
        let orphanedBranches = candidate.branches.filter {
            !currentIDSet.contains($0.id)
        }

        var badges = candidate.badges
        for (scope, count) in baseline.badges where restoredByID[scope] == nil {
            badges[scope] = count
        }
        let selection = candidate.selection.flatMap { selected in
            currentIDSet.contains(selected) ? selected : nil
        } ?? baseline.selection

        let reconciled = try RouterContainerState(
            style: .tabs,
            selection: selection,
            branches: currentBranches + orphanedBranches,
            badges: badges
        )
        return try RouterState(
            root: .container(reconciled),
            windows: restored.windows,
            immersiveSpace: restored.immersiveSpace
        )
    }

    private static func hasCompatibleRestorationTopology(
        _ restored: RouterNode<R>,
        _ baseline: RouterNode<R>
    ) -> Bool {
        switch (restored, baseline) {
        case (.stack, .stack), (.container, .container):
            true
        default:
            false
        }
    }
}
