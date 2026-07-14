import InnoRouterCore

// MARK: - Telemetry adapter helpers
//
// Internal static helpers that translate between the underlying
// `NavigationStoreTelemetryEvent` enum and the public-facing
// `MiddlewareMutationEvent` / `NavigationPathMismatchEvent` shapes.
// They live in this file (not in the main `NavigationStore.swift`)
// so the primary class definition stays focused on the
// `Observable` storage and execution surface. Visibility is bumped
// from `private` to `internal` because the call sites in the main
// initialiser cross file boundaries; the helpers remain absent
// from the public-API baseline because none of them are `public`.
extension NavigationStore {
    static func publicEvent(
        for event: NavigationStoreTelemetryEvent<R>
    ) -> NavigationEvent<R> {
        switch event {
        case .middlewareMutation(let action, let metadata, let index):
            return .middlewareMutation(
                MiddlewareMutationEvent(
                    action: Self.publicAction(for: action),
                    metadata: metadata,
                    index: index
                )
            )
        case .pathMismatch(let policy, let resolution, let oldPath, let newPath):
            return .pathMismatch(
                NavigationPathMismatchEvent(
                    policy: Self.publicPolicy(for: policy),
                    resolution: Self.publicResolution(for: resolution),
                    oldPath: oldPath,
                    newPath: newPath
                )
            )
        }
    }

    static func defaultTelemetrySink(
        for configuration: NavigationStoreConfiguration<R>
    ) -> AnyNavigationTelemetrySink<R>? {
        if let telemetrySink = configuration.telemetrySink {
            return telemetrySink
        }
        guard let logger = configuration.logger else { return nil }
        return AnyNavigationTelemetrySink(OSLogNavigationTelemetrySink<R>(logger: logger))
    }

    static func publicPolicy(
        for policy: NavigationStoreTelemetryEvent<R>.PathMismatchPolicy
    ) -> NavigationPathMismatchEvent<R>.Policy {
        switch policy {
        case .replace: return .replace
        case .assertAndReplace: return .assertAndReplace
        case .ignore: return .ignore
        case .custom: return .custom
        }
    }

    static func publicResolution(
        for resolution: NavigationStoreTelemetryEvent<R>.PathMismatchResolution
    ) -> NavigationPathMismatchEvent<R>.Resolution {
        switch resolution {
        case .single(let command): return .single(command)
        case .batch(let commands): return .batch(commands)
        case .ignore: return .ignore
        }
    }

    static func publicAction(
        for action: NavigationStoreTelemetryEvent<R>.MiddlewareMutation
    ) -> MiddlewareMutationEvent<R>.Action {
        switch action {
        case .added: return .added
        case .inserted: return .inserted
        case .removed: return .removed
        case .replaced: return .replaced
        case .moved: return .moved
        }
    }
}
