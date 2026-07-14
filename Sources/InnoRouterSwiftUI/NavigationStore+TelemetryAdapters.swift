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

    static func makePublicTelemetryRecorder(
        onMiddlewareMutation: (@MainActor @Sendable (MiddlewareMutationEvent<R>) -> Void)?,
        onPathMismatch: (@MainActor @Sendable (NavigationPathMismatchEvent<R>) -> Void)?
    ) -> NavigationStoreTelemetryRecorder<R>? {
        if onMiddlewareMutation == nil && onPathMismatch == nil {
            return nil
        }
        return { @MainActor event in
            switch event {
            case .middlewareMutation(let action, let metadata, let index):
                onMiddlewareMutation?(
                    MiddlewareMutationEvent(
                        action: Self.publicAction(for: action),
                        metadata: metadata,
                        index: index
                    )
                )
            case .pathMismatch(let policy, let resolution, let oldPath, let newPath):
                onPathMismatch?(
                    NavigationPathMismatchEvent(
                        policy: Self.publicPolicy(for: policy),
                        resolution: Self.publicResolution(for: resolution),
                        oldPath: oldPath,
                        newPath: newPath
                    )
                )
            }
        }
    }

    static func makeBroadcastRecorder(
        broadcaster: EventBroadcaster<NavigationEvent<R>>
    ) -> NavigationStoreTelemetryRecorder<R>? {
        { @MainActor event in
            switch event {
            case .middlewareMutation(let action, let metadata, let index):
                broadcaster.broadcast(
                    .middlewareMutation(
                        MiddlewareMutationEvent(
                            action: Self.publicAction(for: action),
                            metadata: metadata,
                            index: index
                        )
                    )
                )
            case .pathMismatch(let policy, let resolution, let oldPath, let newPath):
                broadcaster.broadcast(
                    .pathMismatch(
                        NavigationPathMismatchEvent(
                            policy: Self.publicPolicy(for: policy),
                            resolution: Self.publicResolution(for: resolution),
                            oldPath: oldPath,
                            newPath: newPath
                        )
                    )
                )
            }
        }
    }

    static func makeTelemetrySinkRecorder(
        telemetrySink: AnyNavigationTelemetrySink<R>?
    ) -> NavigationStoreTelemetryRecorder<R>? {
        guard let telemetrySink else { return nil }
        return { @MainActor event in
            switch event {
            case .middlewareMutation(let action, let metadata, let index):
                telemetrySink.record(
                    .middlewareMutation(
                        MiddlewareMutationEvent(
                            action: Self.publicAction(for: action),
                            metadata: metadata,
                            index: index
                        )
                    )
                )
            case .pathMismatch(let policy, let resolution, let oldPath, let newPath):
                telemetrySink.record(
                    .pathMismatch(
                        NavigationPathMismatchEvent(
                            policy: Self.publicPolicy(for: policy),
                            resolution: Self.publicResolution(for: resolution),
                            oldPath: oldPath,
                            newPath: newPath
                        )
                    )
                )
            }
        }
    }

    static func combineRecorders(
        _ primary: NavigationStoreTelemetryRecorder<R>?,
        _ secondary: NavigationStoreTelemetryRecorder<R>?
    ) -> NavigationStoreTelemetryRecorder<R>? {
        switch (primary, secondary) {
        case (nil, nil):
            return nil
        case (let primary?, nil):
            return primary
        case (nil, let secondary?):
            return secondary
        case (let primary?, let secondary?):
            return { event in
                primary(event)
                secondary(event)
            }
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
