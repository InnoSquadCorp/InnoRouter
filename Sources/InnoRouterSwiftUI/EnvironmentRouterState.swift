// MARK: - EnvironmentRouterState.swift
// InnoRouterSwiftUI - macro-first read-only router projection
// Copyright © 2026 Inno Squad. All rights reserved.

import SwiftUI

import InnoRouterCore

/// Reads observation-aware router state from the nearest matching host.
///
/// ```swift
/// @EnvironmentRouterState(AppRoute.self) private var routerState
///
/// var body: some View {
///     Button("Back") { router.back() }
///         .disabled(!routerState.canGoBack)
/// }
/// ```
@MainActor
@propertyWrapper
public struct EnvironmentRouterState<R: Route>: DynamicProperty {
    @Environment(\.routerEnvironment) private var routerEnvironment
    @Environment(\.innoRouterEnvironmentMissingPolicy) private var environmentMissingPolicy
    private let routeType: R.Type

    public init(_ routeType: R.Type) {
        self.routeType = routeType
    }

    public var wrappedValue: RouterStateReader<R> {
        guard let authority = routerEnvironment?[routeType] else {
            handleMissingEnvironment(policy: environmentMissingPolicy) {
                "Router authority is missing for \(String(describing: routeType)) while reading router state. Attach a matching InnoRouter host."
            }
            return RouterStateReader()
        }
        return RouterStateReader(authority: authority.base)
    }
}
