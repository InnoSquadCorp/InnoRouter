// MARK: - StateRestorationAdapter.swift
// InnoRouterSwiftUI - SwiftUI store restoration adapter
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

/// Store snapshot kind handled by ``StateRestorationAdapter``.
public enum StateRestorationTarget: String, Sendable, Equatable {
    case navigationStack
    case flowPlan
}

/// Failure surfaced when a persisted snapshot cannot be decoded or applied.
public struct StateRestorationFailure: Sendable, Equatable {
    public let target: StateRestorationTarget
    public let message: String
}

/// Adapts ``StatePersistence`` to SwiftUI-layer store lifecycles.
///
/// The adapter deliberately does not own storage. Apps can wire the returned
/// `Data` into `SceneStorage`, `AppStorage`, `UserDefaults`, files, or a
/// custom persistence boundary. Decode/apply failures are reported through
/// `onRestorationFailure` and never coerced into an empty stack or empty flow
/// path, so corrupted snapshots stay observable.
@MainActor
public final class StateRestorationAdapter<R: Route & Codable> {
    private let persistence: StatePersistence<R>
    private let onRestorationFailure: @MainActor @Sendable (StateRestorationFailure) -> Void

    public init(
        persistence: StatePersistence<R> = StatePersistence<R>(),
        onRestorationFailure: @escaping @MainActor @Sendable (StateRestorationFailure) -> Void = { _ in }
    ) {
        self.persistence = persistence
        self.onRestorationFailure = onRestorationFailure
    }

    /// Encodes the current navigation stack.
    public func snapshotNavigationStack(from store: NavigationStore<R>) throws -> Data {
        try persistence.encode(store.state)
    }

    /// Decodes and replaces the navigation stack.
    ///
    /// Returns `false` and calls `onRestorationFailure` when decoding fails.
    @discardableResult
    public func restoreNavigationStack(
        from data: Data,
        into store: NavigationStore<R>
    ) -> Bool {
        do {
            let stack = try persistence.decodeStack(data)
            let result = store.execute(.replace(stack.path))
            guard result.isSuccess else {
                onRestorationFailure(
                    StateRestorationFailure(
                        target: .navigationStack,
                        message: "Decoded RouteStack was rejected by the store: \(result)."
                    )
                )
                return false
            }
            return true
        } catch {
            reportFailure(target: .navigationStack, error: error)
            return false
        }
    }

    /// Encodes the current flow path as a `FlowPlan`.
    public func snapshotFlowPlan(from store: FlowStore<R>) throws -> Data {
        try persistence.encode(FlowPlan(steps: store.path))
    }

    /// Decodes and applies a flow plan.
    ///
    /// Returns `false` and calls `onRestorationFailure` when decoding fails or
    /// the store rejects the decoded plan during application.
    @discardableResult
    public func restoreFlowPlan(
        from data: Data,
        into store: FlowStore<R>
    ) -> Bool {
        do {
            let plan = try persistence.decode(data)
            switch store.apply(plan) {
            case .applied:
                return true
            case .rejected:
                onRestorationFailure(
                    StateRestorationFailure(
                        target: .flowPlan,
                        message: "Decoded FlowPlan was rejected by the store."
                    )
                )
                return false
            }
        } catch {
            reportFailure(target: .flowPlan, error: error)
            return false
        }
    }

    private func reportFailure(target: StateRestorationTarget, error: Error) {
        onRestorationFailure(
            StateRestorationFailure(
                target: target,
                message: String(describing: error)
            )
        )
    }
}
