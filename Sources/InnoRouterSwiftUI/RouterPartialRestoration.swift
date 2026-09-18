// MARK: - RouterPartialRestoration.swift
// InnoRouterSwiftUI - app-validated partial snapshot restoration
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

public enum RouterRestorationRouteRole: String, Hashable, Sendable, Codable {
    case path
    case presentation
    case windowRoot
    case immersiveSpaceRoot
}

public struct RouterRestorationRouteLocation: Hashable, Sendable, Codable {
    public let scope: RouterScopePath
    public let role: RouterRestorationRouteRole
    public let index: Int?

    public init(scope: RouterScopePath, role: RouterRestorationRouteRole, index: Int? = nil) {
        self.scope = scope
        self.role = role
        self.index = index
    }
}

/// App-owned validity decision for one decoded and migrated route value.
public enum RouterRestorationRouteDecision<R: Route>: Hashable, Sendable {
    case keep
    case remove(reason: String)
    case replace(with: R, reason: String)
}

public struct RouterPartialRestorationValidator<R: Route>: Sendable {
    private let operation: @MainActor @Sendable (
        R,
        RouterRestorationRouteLocation
    ) async -> RouterRestorationRouteDecision<R>
    private let fallbackOperation: (@MainActor @Sendable (RouterScopePath) async -> R?)?

    public init(
        fallback: (@MainActor @Sendable (RouterScopePath) async -> R?)? = nil,
        validate: @escaping @MainActor @Sendable (
            R,
            RouterRestorationRouteLocation
        ) async -> RouterRestorationRouteDecision<R>
    ) {
        self.operation = validate
        self.fallbackOperation = fallback
    }

    @MainActor
    func validate(
        _ route: R,
        at location: RouterRestorationRouteLocation
    ) async -> RouterRestorationRouteDecision<R> {
        await operation(route, location)
    }

    @MainActor
    func fallback(at scope: RouterScopePath) async -> R? {
        await fallbackOperation?(scope)
    }
}

public enum RouterPartialRestorationChange: String, Hashable, Sendable, Codable {
    case kept
    case removed
    case replaced
    case removedDependentSuffix
}

/// Payload-free explanation of every change made by partial restoration.
public struct RouterPartialRestorationReportEntry: Hashable, Sendable, Codable {
    public let location: RouterRestorationRouteLocation
    public let change: RouterPartialRestorationChange
    public let reason: String

    public init(
        location: RouterRestorationRouteLocation,
        change: RouterPartialRestorationChange,
        reason: String
    ) {
        self.location = location
        self.change = change
        self.reason = reason
    }
}

public struct RouterPartialRestorationReport: Hashable, Sendable, Codable {
    public let entries: [RouterPartialRestorationReportEntry]

    public init(entries: [RouterPartialRestorationReportEntry]) {
        self.entries = entries
    }
}

public enum RouterPartialRestorationError: Error, Hashable, Sendable {
    case validationTimedOut
    case cancelled
    case invalidReplacement(RouterStateValidationError)
    case validationFailed(String)
    case missingRequiredPathFallback(RouterScopePath)
    case invalidPathFallback(RouterScopePath)
    case replacementCycle(RouterRestorationRouteLocation)
    case replacementLimitExceeded(RouterRestorationRouteLocation, maximum: Int)
}

public struct RouterPartialRestorationOutcome<R: Route>: Hashable, Sendable {
    public let report: RouterPartialRestorationReport
    public let transition: RouterOutcome<R>

    public init(report: RouterPartialRestorationReport, transition: RouterOutcome<R>) {
        self.report = report
        self.transition = transition
    }
}

private enum PartialRestorationPlanResult<R: Route>: Sendable {
    case success(RouterState<R>, RouterPartialRestorationReport)
    case failure(RouterPartialRestorationError)
}

@MainActor
private struct PartialRestorationPlanner<R: Route> {
    private static var maximumReplacementCount: Int { 8 }

    private enum ResolvedRoute {
        case kept(R)
        case replaced(R, reason: String)
        case removed(reason: String)
    }

    let validator: RouterPartialRestorationValidator<R>

    func plan(_ source: RouterState<R>) async throws -> (
        RouterState<R>,
        RouterPartialRestorationReport
    ) {
        var report: [RouterPartialRestorationReportEntry] = []
        let root = try await node(source.root, at: .root, report: &report)
        var windows: [RouterWindow<R>] = []
        for window in source.windows {
            try Task.checkCancellation()
            let location = RouterRestorationRouteLocation(
                scope: .window(window.id),
                role: .windowRoot
            )
            switch try await resolve(window.route, at: location) {
            case .kept(let route):
                report.append(.init(
                    location: location,
                    change: .kept,
                    reason: "validator-kept"
                ))
                windows.append(
                    RouterWindow(
                        id: window.id,
                        route: route,
                        node: try await node(window.node, at: .window(window.id), report: &report)
                    )
                )
            case .removed(let reason):
                report.append(.init(location: location, change: .removed, reason: reason))
            case .replaced(let route, let reason):
                report.append(.init(location: location, change: .replaced, reason: reason))
                windows.append(
                    RouterWindow(
                        id: window.id,
                        route: route,
                        node: try await node(window.node, at: .window(window.id), report: &report)
                    )
                )
            }
        }
        var immersive: RouterImmersiveSpace<R>?
        if let sourceSpace = source.immersiveSpace {
            try Task.checkCancellation()
            let location = RouterRestorationRouteLocation(
                scope: .immersiveSpace(sourceSpace.id),
                role: .immersiveSpaceRoot
            )
            switch try await resolve(sourceSpace.route, at: location) {
            case .kept(let route):
                report.append(.init(
                    location: location,
                    change: .kept,
                    reason: "validator-kept"
                ))
                immersive = RouterImmersiveSpace(
                    id: sourceSpace.id,
                    route: route,
                    node: try await node(sourceSpace.node, at: location.scope, report: &report)
                )
            case .removed(let reason):
                report.append(.init(location: location, change: .removed, reason: reason))
            case .replaced(let route, let reason):
                report.append(.init(location: location, change: .replaced, reason: reason))
                immersive = RouterImmersiveSpace(
                    id: sourceSpace.id,
                    route: route,
                    node: try await node(sourceSpace.node, at: location.scope, report: &report)
                )
            }
        }
        do {
            let state = try RouterState(root: root, windows: windows, immersiveSpace: immersive)
            return (state, RouterPartialRestorationReport(entries: report))
        } catch let error as RouterStateValidationError {
            throw RouterPartialRestorationError.invalidReplacement(error)
        }
    }

    private func node(
        _ source: RouterNode<R>,
        at scope: RouterScopePath,
        report: inout [RouterPartialRestorationReportEntry]
    ) async throws -> RouterNode<R> {
        switch source {
        case .stack(let stack):
            var path: [R] = []
            var removedSuffix = false
            for (index, route) in stack.path.enumerated() {
                try Task.checkCancellation()
                let location = RouterRestorationRouteLocation(
                    scope: scope,
                    role: .path,
                    index: index
                )
                if removedSuffix {
                    report.append(.init(
                        location: location,
                        change: .removedDependentSuffix,
                        reason: "invalid-predecessor"
                    ))
                    continue
                }
                switch try await resolve(route, at: location) {
                case .kept(let resolved):
                    path.append(resolved)
                    report.append(.init(
                        location: location,
                        change: .kept,
                        reason: "validator-kept"
                    ))
                case .removed(let reason):
                    removedSuffix = true
                    report.append(.init(location: location, change: .removed, reason: reason))
                case .replaced(let replacement, let reason):
                    path.append(replacement)
                    report.append(.init(location: location, change: .replaced, reason: reason))
                }
            }
            if !stack.path.isEmpty, path.isEmpty {
                try Task.checkCancellation()
                guard let fallback = await validator.fallback(at: scope) else {
                    throw RouterPartialRestorationError.missingRequiredPathFallback(scope)
                }
                try Task.checkCancellation()
                let location = RouterRestorationRouteLocation(
                    scope: scope,
                    role: .path,
                    index: 0
                )
                switch try await resolve(fallback, at: location) {
                case .kept(let resolved):
                    path = [resolved]
                    report.append(.init(
                        location: location,
                        change: .replaced,
                        reason: "fallback-kept"
                    ))
                case .replaced(let replacement, _):
                    path = [replacement]
                    report.append(.init(
                        location: location,
                        change: .replaced,
                        reason: "fallback-replaced"
                    ))
                case .removed:
                    throw RouterPartialRestorationError.invalidPathFallback(scope)
                }
            }
            var presentation = stack.presentation
            if let current = presentation {
                try Task.checkCancellation()
                let location = RouterRestorationRouteLocation(scope: scope, role: .presentation)
                switch try await resolve(current.route, at: location) {
                case .kept(let route):
                    presentation?.route = route
                    report.append(.init(
                        location: location,
                        change: .kept,
                        reason: "validator-kept"
                    ))
                case .removed(let reason):
                    presentation = nil
                    report.append(.init(location: location, change: .removed, reason: reason))
                case .replaced(let route, let reason):
                    presentation?.route = route
                    report.append(.init(location: location, change: .replaced, reason: reason))
                }
            }
            return .stack(path: path, presentation: presentation)
        case .container(let container):
            var branches: [RouterBranch<R>] = []
            for branch in container.branches {
                try Task.checkCancellation()
                let child = try await node(
                    branch.node,
                    at: scope.appending(branch.id),
                    report: &report
                )
                branches.append(RouterBranch(id: branch.id, node: child))
            }
            return .container(
                try RouterContainerState(
                    style: container.style,
                    selection: container.selection,
                    branches: branches,
                    badges: container.badges,
                    split: container.split
                )
            )
        }
    }

    private func validate(
        _ route: R,
        at location: RouterRestorationRouteLocation
    ) async throws -> RouterRestorationRouteDecision<R> {
        try Task.checkCancellation()
        let decision = await validator.validate(route, at: location)
        try Task.checkCancellation()
        return decision
    }

    private func resolve(
        _ route: R,
        at location: RouterRestorationRouteLocation
    ) async throws -> ResolvedRoute {
        var current = route
        var visited: Set<R> = [route]
        var lastReason: String?
        for replacementCount in 0...Self.maximumReplacementCount {
            switch try await validate(current, at: location) {
            case .keep:
                if let lastReason { return .replaced(current, reason: lastReason) }
                return .kept(current)
            case .remove(let reason):
                return .removed(reason: reason)
            case .replace(let replacement, let reason):
                guard replacementCount < Self.maximumReplacementCount else {
                    throw RouterPartialRestorationError.replacementLimitExceeded(
                        location,
                        maximum: Self.maximumReplacementCount
                    )
                }
                guard visited.insert(replacement).inserted else {
                    throw RouterPartialRestorationError.replacementCycle(location)
                }
                current = replacement
                lastReason = reason
            }
        }
        throw RouterPartialRestorationError.replacementLimitExceeded(
            location,
            maximum: Self.maximumReplacementCount
        )
    }
}

@MainActor
package func preparePartialRestoration<R: Route>(
    _ state: RouterState<R>,
    validator: RouterPartialRestorationValidator<R>,
    timeout: Duration?,
    sleep: @escaping @Sendable (Duration) async throws -> Void
) async throws -> (RouterState<R>, RouterPartialRestorationReport) {
    let race = RouterTimeoutRace<PartialRestorationPlanResult<R>>()
    let result = await race.run(timeout: timeout, sleep: sleep) {
        do {
            let value = try await PartialRestorationPlanner(validator: validator).plan(state)
            return .success(value.0, value.1)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as RouterPartialRestorationError {
            return .failure(error)
        } catch {
            return .failure(.validationFailed(String(describing: error)))
        }
    }
    switch result {
    case .value(.success(let state, let report)): return (state, report)
    case .value(.failure(let error)): throw error
    case .timedOut: throw RouterPartialRestorationError.validationTimedOut
    case .cancelled: throw RouterPartialRestorationError.cancelled
    }
}

public extension RouterStore where R: Codable {
    /// Decodes and migrates a snapshot, validates each route with the app,
    /// then applies one exact partial-restoration plan through normal policies.
    func restorePartially(
        from data: Data,
        using codec: RouterSnapshotCodec<R>,
        validator: RouterPartialRestorationValidator<R>,
        validationTimeout: Duration? = nil,
        expectedRevision: UInt64? = nil
    ) async throws -> RouterPartialRestorationOutcome<R> {
        let capturedRevision = expectedRevision ?? revision
        let decoded = try await RouterSnapshotCodecExecutor(codec: codec).decode(data)
        let planned = try await preparePartialRestoration(
            decoded,
            validator: validator,
            timeout: validationTimeout,
            sleep: runtimeDependencies.sleep
        )
        let prepared = try prepareRestoredState(planned.0)
        let transition = await perform(
            .apply(RouterPlan(state: prepared)),
            context: .init(source: .restoration),
            expectedRevision: capturedRevision,
            bypassesPolicies: false
        )
        return RouterPartialRestorationOutcome(report: planned.1, transition: transition)
    }
}
