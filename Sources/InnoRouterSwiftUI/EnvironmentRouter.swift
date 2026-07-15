import SwiftUI

import InnoRouterCore

/// Type-safe navigation, modal, flow, and tab actions exposed by
/// ``EnvironmentRouter``.
///
/// The named methods cover ordinary transitions. `send(_:)` and
/// `send(flow:)` remain escape hatches for advanced intent values without
/// exposing stores or host-owned dispatcher types.
public struct RouterActions<R: Route>: Sendable {
    private enum Capability: String, Sendable {
        case navigation
        case modal
        case flow
        case tab
    }

    private let resolveEnvironment: @MainActor @Sendable () -> RouterEnvironment?
    private let environmentMissingPolicy: EnvironmentMissingPolicy
    private let routeType: R.Type

    /// Retains the navigation-only construction path used by existing hosts
    /// and tests while routing it through the unified authority model.
    @MainActor
    init(
        dispatch: @escaping NavigationIntentHandler<R>
    ) {
        var environment = RouterEnvironment()
        environment[R.self] = RouterAuthority(navigation: dispatch)
        self.resolveEnvironment = { environment }
        self.environmentMissingPolicy = .crash
        self.routeType = R.self
    }

    /// Internal construction hook for focused tests and host composition.
    @MainActor
    init(
        authority: RouterAuthority<R>,
        environmentMissingPolicy: EnvironmentMissingPolicy = .crash
    ) {
        var environment = RouterEnvironment()
        environment[R.self] = authority
        self.resolveEnvironment = { environment }
        self.environmentMissingPolicy = environmentMissingPolicy
        self.routeType = R.self
    }

    @MainActor
    init(
        routeType: R.Type,
        environmentMissingPolicy: EnvironmentMissingPolicy,
        resolveEnvironment: @escaping @MainActor @Sendable () -> RouterEnvironment?
    ) {
        self.resolveEnvironment = resolveEnvironment
        self.environmentMissingPolicy = environmentMissingPolicy
        self.routeType = routeType
    }

    /// Sends a navigation intent without exposing the underlying store.
    @MainActor
    public func send(_ intent: NavigationIntent<R>) {
        guard let handler = navigationHandler(action: "send(NavigationIntent)") else {
            return
        }
        handler(intent)
    }

    /// Sends a modal intent without exposing the underlying store.
    @MainActor
    public func send(_ intent: ModalIntent<R>) {
        guard let handler = modalHandler(action: "send(ModalIntent)") else {
            return
        }
        handler(intent)
    }

    /// Sends a unified-flow intent without exposing the underlying store.
    ///
    /// The `flow` label keeps cases shared with `NavigationIntent` or
    /// `ModalIntent` unambiguous at call sites.
    @MainActor
    public func send(flow intent: FlowIntent<R>) {
        guard let handler = flowHandler(action: "send(flow:)") else {
            return
        }
        handler(intent)
    }

    /// Pushes one route.
    @MainActor
    public func go(_ route: R) {
        guard let handler = navigationHandler(action: "go(_:)") else {
            return
        }
        handler(.go(route))
    }

    /// Pushes multiple routes in one navigation intent.
    @MainActor
    public func goMany(_ routes: [R]) {
        guard let handler = navigationHandler(action: "goMany(_:)") else {
            return
        }
        handler(.goMany(routes))
    }

    /// Pops one route.
    @MainActor
    public func back() {
        guard let handler = navigationHandler(action: "back()") else {
            return
        }
        handler(.back)
    }

    /// Pops `count` routes.
    @MainActor
    public func back(by count: Int) {
        guard let handler = navigationHandler(action: "back(by:)") else {
            return
        }
        handler(.backBy(count))
    }

    /// Pops back to `route` when it exists in the stack.
    @MainActor
    public func back(to route: R) {
        guard let handler = navigationHandler(action: "back(to:)") else {
            return
        }
        handler(.backTo(route))
    }

    /// Pops every route above the root view.
    @MainActor
    public func backToRoot() {
        guard let handler = navigationHandler(action: "backToRoot()") else {
            return
        }
        handler(.backToRoot)
    }

    /// Presents `route` as a sheet.
    @MainActor
    public func sheet(_ route: R) {
        guard let handler = modalHandler(action: "sheet(_:)") else {
            return
        }
        handler(.present(route, style: .sheet))
    }

    /// Presents `route` as a full-screen cover.
    ///
    /// On platforms without native full-screen-cover support, the host applies
    /// its documented adaptive presentation behavior.
    @MainActor
    public func cover(_ route: R) {
        guard let handler = modalHandler(action: "cover(_:)") else {
            return
        }
        handler(.present(route, style: .fullScreenCover))
    }

    /// Dismisses the active modal presentation.
    @MainActor
    public func dismiss() {
        guard let handler = modalHandler(action: "dismiss()") else {
            return
        }
        handler(.dismiss)
    }

    /// Dismisses the active and queued modal presentations.
    @MainActor
    public func dismissAll() {
        guard let handler = modalHandler(action: "dismissAll()") else {
            return
        }
        handler(.dismissAll)
    }

    @MainActor
    private func navigationHandler(action: String) -> NavigationIntentHandler<R>? {
        authority(capability: .navigation, action: action)?.navigation
    }

    @MainActor
    private func modalHandler(action: String) -> ModalIntentHandler<R>? {
        authority(capability: .modal, action: action)?.modal
    }

    @MainActor
    private func flowHandler(action: String) -> FlowIntentHandler<R>? {
        authority(capability: .flow, action: action)?.flow
    }

    @MainActor
    private func tabHandler(action: String) -> RouterTabActionHandler<R>? {
        authority(capability: .tab, action: action)?.tab
    }

    @MainActor
    private func authority(
        capability: Capability,
        action: String
    ) -> RouterAuthority<R>? {
        guard let environment = resolveEnvironment() else {
            reportMissing {
                "Router environment is missing for \(String(describing: routeType)) while invoking \(action). " +
                "Attach this view inside a matching InnoRouter host."
            }
            return nil
        }

        guard let authority = environment[routeType] else {
            reportMissing {
                "Router authority is missing for \(String(describing: routeType)) while invoking \(action). " +
                "Ensure the nearest InnoRouter host uses the same route type."
            }
            return nil
        }

        let hasCapability: Bool
        switch capability {
        case .navigation:
            hasCapability = authority.navigation != nil
        case .modal:
            hasCapability = authority.modal != nil
        case .flow:
            hasCapability = authority.flow != nil
        case .tab:
            hasCapability = authority.tab != nil
        }

        guard hasCapability else {
            reportMissing {
                "Router \(capability.rawValue) capability is missing for \(String(describing: routeType)) " +
                "while invoking \(action). Attach a host that owns this capability."
            }
            return nil
        }

        return authority
    }

    @MainActor
    private func reportMissing(_ message: () -> String) {
        handleMissingEnvironment(
            policy: environmentMissingPolicy,
            message: message
        )
    }
}

public extension RouterActions where R: RouterTab {
    /// Selects a tab owned by the nearest matching ``RouterTabHost``.
    @MainActor
    func select(_ tab: R) {
        guard let handler = tabHandler(action: "select(_:)") else {
            return
        }
        handler(.select(tab))
    }

    /// Sets a positive badge count, or clears the badge for non-positive
    /// values, on the nearest matching ``RouterTabHost``.
    @MainActor
    func setBadge(_ count: Int, for tab: R) {
        guard let handler = tabHandler(action: "setBadge(_:for:)") else {
            return
        }
        handler(.setBadge(count, for: tab))
    }

    /// Clears the badge for one tab.
    @MainActor
    func clearBadge(for tab: R) {
        guard let handler = tabHandler(action: "clearBadge(for:)") else {
            return
        }
        handler(.setBadge(nil, for: tab))
    }

    /// Clears every badge owned by the nearest matching ``RouterTabHost``.
    @MainActor
    func clearAllBadges() {
        guard let handler = tabHandler(action: "clearAllBadges()") else {
            return
        }
        handler(.clearAllBadges)
    }
}

/// Reads route actions from the nearest route-typed InnoRouter authority.
///
/// Resolution is lazy: reading the property or rendering a host-less view does
/// not report an error. ``EnvironmentMissingPolicy`` is consulted only when an
/// action is invoked and the matching host, route type, or requested
/// capability is unavailable.
///
/// ```swift
/// struct HomeView: View {
///     @EnvironmentRouter(AppRoute.self) private var router
///
///     var body: some View {
///         Button("Open detail") {
///             router.go(.detail(id: "42"))
///         }
///     }
/// }
/// ```
@MainActor
@propertyWrapper
public struct EnvironmentRouter<R: Route>: DynamicProperty {
    @Environment(\.routerEnvironment) private var routerEnvironment
    @Environment(\.innoRouterEnvironmentMissingPolicy) private var environmentMissingPolicy
    private let routeType: R.Type

    public init(_ routeType: R.Type) {
        self.routeType = routeType
    }

    public var wrappedValue: RouterActions<R> {
        // Capture the current value-semantic environment snapshot. The typed
        // lookup itself remains deferred until a RouterActions method runs.
        let environment = routerEnvironment
        return RouterActions(
            routeType: routeType,
            environmentMissingPolicy: environmentMissingPolicy,
            resolveEnvironment: { environment }
        )
    }
}
