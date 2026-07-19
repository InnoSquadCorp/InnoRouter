import InnoRouterCore

@MainActor
extension NavigationStore {
    // `internal` because the SwiftUI binding adapters live in a separate file.
    // The reconciliation policy remains an implementation detail of this module.
    internal func reconcileNavigationPath(
        with newPath: [R],
        policyOverride: NavigationPathMismatchPolicy<R>? = nil
    ) {
        eventDispatcher.withExecutionBoundary {
            NavigationPathReconciler<R>().reconcile(
                from: state.path,
                to: newPath,
                resolveMismatch: { [weak self] oldPath, newPath in
                    guard let self else { return .single(.replace(newPath)) }
                    return self.resolvePathMismatch(
                        from: oldPath,
                        to: newPath,
                        policyOverride: policyOverride
                    )
                },
                execute: { [weak self] command in
                    guard let self else { return }
                    _ = self.execute(command)
                },
                executeBatch: { [weak self] commands in
                    guard let self else { return }
                    _ = self.executeBatch(commands, stopOnFailure: false)
                }
            )
        }
    }

    private func resolvePathMismatch(
        from oldPath: [R],
        to newPath: [R],
        policyOverride: NavigationPathMismatchPolicy<R>? = nil
    ) -> NavigationPathMismatchResolution<R> {
        let policy: NavigationStoreTelemetryEvent<R>.PathMismatchPolicy
        let resolution: NavigationPathMismatchResolution<R>

        let effectivePolicy = policyOverride ?? pathMismatchPolicy
        switch effectivePolicy {
        case .replace:
            policy = .replace
            resolution = .single(.replace(newPath))

        case .assertAndReplace:
            policy = .assertAndReplace
            pathMismatchAssertionHandler(oldPath, newPath)
            resolution = .single(.replace(newPath))

        case .ignore:
            policy = .ignore
            resolution = .ignore

        case .custom(let transform):
            policy = .custom
            resolution = transform(oldPath, newPath)
        }

        telemetrySink.recordPathMismatch(
            policy: policy,
            resolution: resolution,
            oldPath: oldPath,
            newPath: newPath
        )
        return resolution
    }
}
