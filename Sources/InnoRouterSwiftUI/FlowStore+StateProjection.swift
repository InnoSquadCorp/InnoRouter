// MARK: - FlowStore+StateProjection.swift
// InnoRouterSwiftUI - read-only projections of FlowStore state.
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

extension FlowStore {
    /// The push prefix of ``path`` projected as plain routes (i.e. the same
    /// routes that would be visible in a `NavigationStack(path:)`).
    public var navigationPath: [R] {
        path.compactMap { step in
            if case .push(let route) = step { return route }
            return nil
        }
    }

    /// The currently visible modal route if ``path`` ends in a `.sheet(_)`
    /// or `.cover(_)` step, otherwise `nil`.
    public var currentModalRoute: R? {
        guard let last = path.last else { return nil }
        switch last {
        case .sheet(let route), .cover(let route):
            return route
        case .push:
            return nil
        }
    }

    /// The currently visible modal presentation, including its presentation
    /// style and stable identity. Returns `nil` when there is no trailing
    /// modal.
    public var currentModalPresentation: ModalPresentation<R>? {
        modalStore.currentPresentation
    }

    /// Whether the flow currently has a trailing modal step.
    public var hasModalTail: Bool {
        currentModalRoute != nil
    }

    internal var currentMutationContext: FlowMutationContext {
        FlowMutationContext(
            navigationState: navigationStore.state,
            modalState: modalStore.flowStateSnapshot
        )
    }

    private var currentProjection: FlowProjection {
        currentMutationContext.projection
    }

    internal func syncPathFromStores(from oldPath: [RouteStep<R>]) {
        syncPath(from: oldPath, projection: currentProjection)
    }

    internal func syncPathFromStoresWithoutEmitting() {
        assignPath(currentProjection.path)
    }

    private func syncPath(
        from oldPath: [RouteStep<R>],
        projection: FlowProjection
    ) {
        assignPath(projection.path)
        guard oldPath != path else { return }
        emitFlowEvent(.pathChanged(old: oldPath, new: path))
    }

    internal struct FlowProjection {
        let pushRoutes: [R]
        let currentPresentation: ModalPresentation<R>?
        let queuedPresentations: [ModalPresentation<R>]

        var path: [RouteStep<R>] {
            var projectedPath = pushRoutes.map(RouteStep.push)
            if let currentPresentation {
                projectedPath.append(FlowStore.step(for: currentPresentation))
            }
            return projectedPath
        }
    }

    internal struct FlowMutationContext {
        let navigationState: RouteStack<R>
        let modalState: ModalExecutionState<R>

        var projection: FlowProjection {
            FlowProjection(
                pushRoutes: navigationState.path,
                currentPresentation: modalState.currentPresentation,
                queuedPresentations: modalState.queuedPresentations
            )
        }
    }
}
