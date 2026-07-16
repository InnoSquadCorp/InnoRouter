import InnoRouterCore

/// Framework-internal reducer that turns SwiftUI path mutations into typed
/// commands. Keeping one implementation protects the store's prefix and
/// mismatch invariants; apps customize non-prefix behavior through
/// ``NavigationPathMismatchPolicy`` instead of replacing this algorithm.
struct NavigationPathReconciler<R: Route> {

    nonisolated init() {}

    @MainActor
    func reconcile(
        from oldPath: [R],
        to newPath: [R],
        resolveMismatch: @MainActor ([R], [R]) -> NavigationPathMismatchResolution<R>,
        execute: @MainActor (NavigationCommand<R>) -> Void,
        executeBatch: @MainActor ([NavigationCommand<R>]) -> Void
    ) {
        guard oldPath != newPath else { return }

        let commonPrefixLength = Self.longestCommonPrefixLength(between: oldPath, and: newPath)

        if commonPrefixLength == newPath.count {
            let countToPop = oldPath.count - newPath.count
            guard countToPop > 0 else { return }
            if countToPop == oldPath.count {
                execute(.popToRoot)
            } else {
                execute(.popCount(countToPop))
            }
            return
        }

        if commonPrefixLength == oldPath.count {
            let appendedRoutes = Array(newPath.dropFirst(commonPrefixLength))
            switch appendedRoutes.count {
            case 0:
                return
            case 1:
                execute(.push(appendedRoutes[0]))
            default:
                executeBatch(appendedRoutes.map(NavigationCommand.push))
            }
            return
        }

        switch resolveMismatch(oldPath, newPath) {
        case .single(let command):
            execute(command)
        case .batch(let commands):
            executeBatch(commands)
        case .ignore:
            return
        }
    }

    private static func longestCommonPrefixLength(between lhs: [R], and rhs: [R]) -> Int {
        zip(lhs, rhs).prefix { pair in
            pair.0 == pair.1
        }.count
    }
}
