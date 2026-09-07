import SwiftUI

import InnoRouterCore

/// Type-safe actions forwarded to the nearest canonical `RouterStore` scope.
public struct RouterActions<R: Route>: Sendable {
    private let environment: RouterEnvironment?
    private let environmentMissingPolicy: EnvironmentMissingPolicy
    private let routeType: R.Type

    @MainActor
    init(
        authority: RouterAuthority<R>,
        environmentMissingPolicy: EnvironmentMissingPolicy = .crash
    ) {
        var environment = RouterEnvironment()
        environment[R.self] = authority
        self.environment = environment
        self.environmentMissingPolicy = environmentMissingPolicy
        routeType = R.self
    }

    @MainActor
    init(
        routeType: R.Type,
        environmentMissingPolicy: EnvironmentMissingPolicy,
        environment: RouterEnvironment?
    ) {
        self.environment = environment
        self.environmentMissingPolicy = environmentMissingPolicy
        self.routeType = routeType
    }

    @MainActor
    public func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        guard let authority = routerAuthority(action: "perform(_:context:)") else {
            return missingAuthorityOutcome()
        }
        return await authority.perform(action, context: context, expectedRevision: nil)
    }

    @MainActor @discardableResult
    public func dispatch(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) -> Task<RouterOutcome<R>, Never> {
        guard let authority = routerAuthority(action: "dispatch(_:context:)") else {
            return missingAuthorityTask()
        }
        return Task { @MainActor in
            await authority.perform(action, context: context, expectedRevision: nil)
        }
    }

    @MainActor @discardableResult
    public func go(_ route: R) -> Task<RouterOutcome<R>, Never> { dispatch(.push(route)) }

    /// Pushes only when `route` is not already at the top of this scope.
    @MainActor @discardableResult
    public func goIfNeeded(_ route: R) -> Task<RouterOutcome<R>, Never> {
        dispatch(.pushIfNeeded(route))
    }

    /// Pops back to `route` when present, or pushes it when absent.
    @MainActor @discardableResult
    public func backOrGo(_ route: R) -> Task<RouterOutcome<R>, Never> {
        dispatch(.backOrPush(route))
    }

    /// Replaces the top destination, or pushes when the path is empty.
    @MainActor @discardableResult
    public func replaceTop(with route: R) -> Task<RouterOutcome<R>, Never> {
        dispatch(.replaceTop(route))
    }

    @MainActor @discardableResult
    public func goMany(_ routes: [R]) -> Task<RouterOutcome<R>, Never> {
        dispatch(.pushMany(routes))
    }

    @MainActor @discardableResult
    public func back() -> Task<RouterOutcome<R>, Never> { dispatch(.pop(count: 1)) }

    @MainActor @discardableResult
    public func back(by count: Int) -> Task<RouterOutcome<R>, Never> {
        dispatch(.pop(count: count))
    }

    @MainActor @discardableResult
    public func back(to route: R) -> Task<RouterOutcome<R>, Never> { dispatch(.popTo(route)) }

    @MainActor @discardableResult
    public func backToRoot() -> Task<RouterOutcome<R>, Never> { dispatch(.popToRoot) }

    @MainActor @discardableResult
    public func sheet(_ route: R) -> Task<RouterOutcome<R>, Never> {
        dispatch(.present(.init(route: route, style: .sheet)))
    }

    @MainActor @discardableResult
    public func cover(_ route: R) -> Task<RouterOutcome<R>, Never> {
        dispatch(.present(.init(route: route, style: .fullScreenCover)))
    }

    @MainActor
    public func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle = .sheet,
        options: RouterPresentationOptions = .init(),
        expecting: Value.Type = Value.self
    ) async -> RouterPresentationOutcome<Value> {
        guard let authority = routerAuthority(action: "present(_:style:options:expecting:)") else {
            return .rejected(.missingAuthority(routeType: String(describing: routeType)))
        }
        return await authority.present(
            route,
            style: style,
            options: options,
            expecting: expecting
        )
    }

    @MainActor
    public func present<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>
    ) async -> RouterPresentationOutcome<Value> {
        guard let authority = routerAuthority(action: "present(_:)") else {
            return .rejected(.missingAuthority(routeType: String(describing: routeType)))
        }
        return await authority.present(request)
    }

    @MainActor
    public func finishPresentation<Value: Sendable>(returning value: Value) async throws {
        guard let authority = routerAuthority(action: "finishPresentation(returning:)") else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: .root)
        }
        try await authority.finishPresentation(returning: value)
    }

    @MainActor
    public func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value
    ) async throws {
        guard let authority = routerAuthority(action: "finishPresentation(_:returning:)") else {
            throw RouterPresentationCompletionError.noActivePresentation(scope: .root)
        }
        try await authority.finishPresentation(request, returning: value)
    }

    @MainActor @discardableResult
    public func dismiss() -> Task<RouterOutcome<R>, Never> { dispatch(.dismissPresentation) }

    /// Selects one declared detent for the active presentation in this scope.
    @MainActor @discardableResult
    public func setPresentationDetent(
        _ detent: RouterPresentationDetent
    ) -> Task<RouterOutcome<R>, Never> {
        dispatch(.setPresentationDetent(detent))
    }

    @MainActor @discardableResult
    public func apply(_ plan: RouterPlan<R>) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.apply(plan), action: "apply(_:)")
    }

    @MainActor @discardableResult
    public func transaction(
        @RouterPlanBuilder<R> _ build: () -> [RouterPlanStep<R>]
    ) throws -> Task<RouterOutcome<R>, Never> {
        guard let authority = routerAuthority(action: "transaction(_:)") else {
            return missingAuthorityTask()
        }
        guard let state = authority.state else { return missingAuthorityTask() }
        let plan = try RouterPlan(from: state, build)
        return Task { @MainActor in
            await authority.performRoot(
                .apply(plan),
                context: .init(),
                expectedRevision: authority.authorityRevision
            )
        }
    }

    /// Updates native split-column visibility at the owning store root.
    @MainActor @discardableResult
    public func setSplitVisibility(
        _ visibility: RouterSplitVisibility
    ) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(
            .setSplitVisibility(visibility),
            action: "setSplitVisibility(_:)"
        )
    }

    /// Updates which native split column is preferred in compact layouts.
    @MainActor @discardableResult
    public func setPreferredCompactColumn(
        _ column: RouterSplitColumn
    ) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(
            .setPreferredCompactColumn(column),
            action: "setPreferredCompactColumn(_:)"
        )
    }

    @MainActor
    private func routerAuthority(
        action: String
    ) -> (any RouterAuthorityProtocol<R>)? {
        guard let environment, let authority = environment[routeType] else {
            handleMissingEnvironment(policy: environmentMissingPolicy) {
                "Router authority is missing for \(String(describing: routeType)) while invoking \(action). Attach a matching InnoRouter host."
            }
            return nil
        }
        return authority.base
    }

    @MainActor
    private func rootDispatch(
        _ action: RouterAction<R>,
        action name: String
    ) -> Task<RouterOutcome<R>, Never> {
        guard let authority = routerAuthority(action: name) else {
            return missingAuthorityTask()
        }
        return Task { @MainActor in
            await authority.performRoot(action, context: .init(), expectedRevision: nil)
        }
    }

    @MainActor
    private func missingAuthorityOutcome() -> RouterOutcome<R> {
        .rejected(
            id: .init(),
            state: .rootStack,
            revision: 0,
            reason: .missingAuthority(routeType: String(describing: routeType))
        )
    }

    @MainActor
    private func missingAuthorityTask() -> Task<RouterOutcome<R>, Never> {
        let outcome = missingAuthorityOutcome()
        return Task { outcome }
    }
}

public extension RouterActions where R: RouterSceneRoute {
    /// Opens one macro-generated regular-window destination.
    @MainActor @discardableResult
    func openWindow(
        _ request: RouterWindowRequest<R>,
        id: UUID = UUID()
    ) -> Task<RouterOutcome<R>, Never> {
        guard let scene = R.routerScene(for: request.route),
              scene.style == .window,
              scene.id == request.sceneID else {
            return sceneRejectionTask(style: .window)
        }
        return openWindow(request.route, id: id)
    }

    @MainActor @discardableResult
    func openWindow(_ route: R, id: UUID = UUID()) -> Task<RouterOutcome<R>, Never> {
        guard let scene = R.routerScene(for: route), scene.style == .window else {
            return sceneRejectionTask(style: .window)
        }
#if os(tvOS) || os(watchOS)
        return sceneRejectionTask(style: .window)
#else
        return rootDispatch(
            .openWindow(.init(id: id, route: route)),
            action: "openWindow(_:id:)"
        )
#endif
    }

    @MainActor @discardableResult
    func dismissWindow(_ id: UUID) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.dismissWindow(id), action: "dismissWindow(_:)")
    }

    @MainActor @discardableResult
    func enterImmersiveSpace(
        id: String,
        route: R
    ) -> Task<RouterOutcome<R>, Never> {
        guard let scene = R.routerScene(for: route), scene.style == .immersiveSpace else {
            return sceneRejectionTask(style: .immersiveSpace)
        }
        guard scene.id == id else {
            return sceneRejectionTask(
                reason: .sceneIdentifierMismatch(expected: scene.id, actual: id)
            )
        }
#if os(visionOS)
        return rootDispatch(
            .enterImmersiveSpace(.init(id: id, route: route)),
            action: "enterImmersiveSpace(id:route:)"
        )
#else
        return sceneRejectionTask(style: .immersiveSpace)
#endif
    }

    /// Opens one macro-generated immersive destination without duplicating its
    /// application-owned scene identifier at the call site.
    @MainActor @discardableResult
    func enterImmersiveSpace(
        _ request: RouterImmersiveSpaceRequest<R>
    ) -> Task<RouterOutcome<R>, Never> {
        enterImmersiveSpace(id: request.sceneID, route: request.route)
    }

    @MainActor @discardableResult
    func dismissImmersiveSpace() -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.dismissImmersiveSpace, action: "dismissImmersiveSpace()")
    }

    @MainActor
    private func sceneRejectionTask(
        style: RouterSceneStyle
    ) -> Task<RouterOutcome<R>, Never> {
        sceneRejectionTask(
            reason: .unsupportedScene(
                routeType: String(describing: R.self),
                style: style.rawValue
            )
        )
    }

    @MainActor
    private func sceneRejectionTask(
        reason: RouterMutationError
    ) -> Task<RouterOutcome<R>, Never> {
        guard let authority = routerAuthority(action: "scene action") else {
            return missingAuthorityTask()
        }
        let outcome = authority.reject(.mutation(reason))
        return Task { outcome }
    }
}

public extension RouterActions where R: RouterTabRoute {
    @MainActor @discardableResult
    func select(_ tab: R.Tab) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.select(tab.routerScopeID), action: "select(_:)")
    }

    @MainActor @discardableResult
    func setBadge(_ count: Int, for tab: R.Tab) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.setBadge(count, for: tab.routerScopeID), action: "setBadge(_:for:)")
    }

    @MainActor @discardableResult
    func clearBadge(for tab: R.Tab) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.setBadge(nil, for: tab.routerScopeID), action: "clearBadge(for:)")
    }

    @MainActor @discardableResult
    func clearAllBadges() -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.clearAllBadges, action: "clearAllBadges()")
    }
}

/// Reads route actions from the nearest route-typed InnoRouter authority.
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
        RouterActions(
            routeType: routeType,
            environmentMissingPolicy: environmentMissingPolicy,
            environment: routerEnvironment
        )
    }
}
