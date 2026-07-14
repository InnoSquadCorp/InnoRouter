public struct NavigationEngine<R: Route>: Sendable {
    public init() {}

    public func apply(_ command: NavigationCommand<R>, to state: inout RouteStack<R>) -> NavigationResult<R> {
        switch command {
        case .push(let route):
            state.path.append(route)
            return .success

        case .pushAll(let routes):
            state.path.append(contentsOf: routes)
            return .success

        case .pop:
            guard !state.path.isEmpty else { return .emptyStack }
            _ = state.path.removeLast()
            return .success

        case .popCount(let count):
            guard count > 0 else { return .invalidPopCount(count) }
            guard count <= state.path.count else {
                return .insufficientStackDepth(requested: count, available: state.path.count)
            }
            state.path.removeLast(count)
            return .success

        case .popToRoot:
            state.path.removeAll()
            return .success

        case .popTo(let route):
            guard let index = state.path.lastIndex(of: route) else { return .routeNotFound(route) }
            state.path = Array(state.path.prefix(through: index))
            return .success

        case .replace(let routes):
            state.path = routes
            return .success

        case .sequence(let commands):
            let results = commands.map { apply($0, to: &state) }
            return .multiple(results)

        case .whenCancelled(let primary, let fallback):
            let snapshot = state
            var primaryState = snapshot
            let primaryResult = apply(primary, to: &primaryState)
            if primaryResult.isSuccess {
                state = primaryState
                return primaryResult
            }

            var fallbackState = snapshot
            let fallbackResult = apply(fallback, to: &fallbackState)
            state = fallbackResult.isSuccess ? fallbackState : snapshot
            return fallbackResult
        }
    }
}
