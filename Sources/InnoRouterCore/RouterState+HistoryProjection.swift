import Foundation

package extension RouterState {
    /// A narrowing transform of already-valid state. It removes presentations
    /// and badges without changing identities, selections, scene roots or paths.
    /// It neither re-admits under unrelated default limits nor truncates paths.
    func navigationHistoryProjection() -> Self {
        var result = self
        result.root = Self.historyNode(root)
        result.windows = windows.map { RouterWindow(id: $0.id, route: $0.route, node: Self.historyNode($0.node)) }
        result.immersiveSpace = immersiveSpace.map {
            RouterImmersiveSpace(id: $0.id, route: $0.route, node: Self.historyNode($0.node))
        }
        return result
    }

    private static func historyNode(_ node: RouterNode<R>) -> RouterNode<R> {
        switch node {
        case .stack(let stack): return .stack(path: stack.path)
        case .container(let container):
            var result = container
            result.branches = container.branches.map { RouterBranch(id: $0.id, node: historyNode($0.node)) }
            result.badges = [:]
            return .container(result)
        }
    }
}
