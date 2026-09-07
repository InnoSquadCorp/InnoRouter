import InnoRouterCore

extension RouterHistory {
    nonisolated package static func navigationProjection(
        _ state: RouterState<R>
    ) -> RouterState<R> {
        var result = state
        result.root = project(state.root)
        result.windows = state.windows.map {
            RouterWindow(id: $0.id, route: $0.route, node: project($0.node))
        }
        result.immersiveSpace = state.immersiveSpace.map {
            RouterImmersiveSpace(id: $0.id, route: $0.route, node: project($0.node))
        }
        return result
    }

    nonisolated private static func project(_ node: RouterNode<R>) -> RouterNode<R> {
        switch node {
        case .stack(let stack):
            return .stack(path: stack.path)
        case .container(let container):
            var projected = container
            projected.branches = container.branches.map {
                RouterBranch(id: $0.id, node: project($0.node))
            }
            projected.badges = [:]
            return .container(projected)
        }
    }

    nonisolated package static func hasSameNavigation(
        _ lhs: RouterState<R>,
        _ rhs: RouterState<R>
    ) -> Bool {
        guard lhs.root == rhs.root else { return false }
        let rhsWindows = Dictionary(uniqueKeysWithValues: rhs.windows.map { ($0.id, $0.node) })
        for window in lhs.windows {
            if let rhsNode = rhsWindows[window.id], rhsNode != window.node { return false }
        }
        let lhsWindows = Dictionary(uniqueKeysWithValues: lhs.windows.map { ($0.id, $0.node) })
        for window in rhs.windows {
            if let lhsNode = lhsWindows[window.id], lhsNode != window.node { return false }
        }
        if let lhsSpace = lhs.immersiveSpace,
           let rhsSpace = rhs.immersiveSpace,
           lhsSpace.id == rhsSpace.id,
           lhsSpace.node != rhsSpace.node {
            return false
        }
        return true
    }

    nonisolated package static func merge(
        _ target: RouterState<R>,
        into current: RouterState<R>
    ) throws -> RouterState<R> {
        let root = try mergeNode(target.root, into: current.root, at: .root)
        let targetWindows = Dictionary(uniqueKeysWithValues: target.windows.map { ($0.id, $0) })
        let windows = try current.windows.map { currentWindow in
            guard let targetWindow = targetWindows[currentWindow.id] else { return currentWindow }
            return RouterWindow(
                id: currentWindow.id,
                route: currentWindow.route,
                node: try mergeNode(
                    targetWindow.node,
                    into: currentWindow.node,
                    at: .window(currentWindow.id)
                )
            )
        }
        let immersive: RouterImmersiveSpace<R>?
        if let currentSpace = current.immersiveSpace,
           let targetSpace = target.immersiveSpace,
           currentSpace.id == targetSpace.id {
            immersive = RouterImmersiveSpace(
                id: currentSpace.id,
                route: currentSpace.route,
                node: try mergeNode(
                    targetSpace.node,
                    into: currentSpace.node,
                    at: .immersiveSpace(currentSpace.id)
                )
            )
        } else {
            immersive = current.immersiveSpace
        }
        return try RouterState(root: root, windows: windows, immersiveSpace: immersive)
    }

    nonisolated package static func prepareNavigationMerge(
        _ target: RouterState<R>,
        into current: RouterState<R>
    ) -> RouterDeferredResumePreparation<R> {
        do {
            return .action(.apply(RouterPlan(state: try merge(target, into: current))))
        } catch RouterHistoryFailure.activePresentation(let path) {
            return .rejected(.mutation(.blockedByPresentation(path)))
        } catch RouterHistoryFailure.incompatibleTopology(let path) {
            return .rejected(.mutation(.incompatibleNavigationTopology(path)))
        } catch {
            return .rejected(.mutation(.incompatibleNavigationTopology(.root)))
        }
    }

    nonisolated private static func mergeNode(
        _ target: RouterNode<R>,
        into current: RouterNode<R>,
        at path: RouterScopePath
    ) throws -> RouterNode<R> {
        switch (target, current) {
        case (.stack(let targetStack), .stack(let currentStack)):
            if targetStack.path != currentStack.path, currentStack.presentation != nil {
                throw RouterHistoryFailure.activePresentation(path)
            }
            return .stack(
                path: targetStack.path,
                presentation: currentStack.presentation
            )
        case (.container(let targetContainer), .container(let currentContainer)):
            let targetIDs = targetContainer.branches.map(\.id)
            let currentIDs = currentContainer.branches.map(\.id)
            guard targetContainer.style == currentContainer.style,
                  targetIDs == currentIDs else {
                throw RouterHistoryFailure.incompatibleTopology(path)
            }
            let branches = try zip(targetContainer.branches, currentContainer.branches).map {
                RouterBranch(
                    id: $1.id,
                    node: try mergeNode($0.node, into: $1.node, at: path.appending($1.id))
                )
            }
            return .container(try RouterContainerState(
                style: currentContainer.style,
                selection: targetContainer.selection,
                branches: branches,
                badges: currentContainer.badges,
                split: targetContainer.split
            ))
        default:
            throw RouterHistoryFailure.incompatibleTopology(path)
        }
    }
}
