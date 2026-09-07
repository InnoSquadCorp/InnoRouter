import SwiftUI

import InnoRouterCore

package typealias RouterRequestPrecondition<R: Route> = @MainActor @Sendable (
    RouterState<R>
) -> RouterRejectionReason?

package enum RouterDeferredResumePreparation<R: Route>: Sendable {
    case action(RouterAction<R>)
    case rejected(RouterRejectionReason)
}

package typealias RouterDeferredResumePreparationBuilder<R: Route> = @MainActor @Sendable (
    RouterState<R>,
    RouterDeferralResumeStrategy
) -> RouterDeferredResumePreparation<R>

package typealias RouterRequestPreparationBuilder<R: Route> = @MainActor @Sendable (
    RouterState<R>
) -> RouterDeferredResumePreparation<R>

/// Internal behavior shared by a direct store scope and a typed feature
/// projection. Both paths ultimately execute on one canonical `RouterStore`.
@MainActor
protocol RouterAuthorityProtocol<R>: AnyObject, Sendable {
    associatedtype R: Route

    var path: RouterScopePath { get }
    var node: RouterNode<R>? { get }
    var state: RouterState<R>? { get }
    var observedPath: [R] { get }
    var observedSceneRootRoute: R? { get }
    var observedPresentation: RouterPresentation<R>? { get }
    var observedSelection: RouterScopeID? { get }
    var observedBadges: [RouterScopeID: Int] { get }
    var observedSplitState: RouterSplitState? { get }
    var observedWindows: [RouterWindow<R>] { get }
    var observedImmersiveSpace: RouterImmersiveSpace<R>? { get }
    var reconciliationRevision: UInt64 { get }
    var authorityRevision: UInt64 { get }
    /// Location of this authority's node inside states returned by its outcome.
    var outcomeScopePath: RouterScopePath { get }

    func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) async -> RouterOutcome<R>
    func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R>
    func performRoot(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?
    ) async -> RouterOutcome<R>
    func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type
    ) async -> RouterPresentationOutcome<Value>
    func present<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value>
    func present<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>
    ) async -> RouterPresentationOutcome<Value>
    func finishPresentation<Value: Sendable>(returning value: Value) async throws
    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value
    ) async throws
    func reject(_ reason: RouterRejectionReason) -> RouterOutcome<R>
    func reportPlatformAdaptation(_ adaptation: RouterPlatformAdaptation)
}

/// The one canonical authority published for a route type.
struct RouterAuthority<R: Route>: Sendable {
    let base: any RouterAuthorityProtocol<R>

    init(scope: RouterScope<R>) {
        self.base = scope
    }

    init(base: some RouterAuthorityProtocol<R>) {
        self.base = base
    }
}

@MainActor
private final class ErasedRouterAuthority: Sendable {
    private let value: Any

    init<R: Route>(_ authority: RouterAuthority<R>) {
        value = authority
    }

    func authority<R: Route>(for routeType: R.Type) -> RouterAuthority<R>? {
        _ = routeType
        return value as? RouterAuthority<R>
    }
}

/// Value-semantic route-type registry inherited through the SwiftUI tree.
struct RouterEnvironment: Sendable {
    private var authorities: [ObjectIdentifier: ErasedRouterAuthority] = [:]

    @MainActor
    subscript<R: Route>(routeType: R.Type) -> RouterAuthority<R>? {
        get {
            authorities[ObjectIdentifier(routeType)]?.authority(for: routeType)
        }
        set {
            let key = ObjectIdentifier(routeType)
            if let newValue {
                authorities[key] = ErasedRouterAuthority(newValue)
            } else {
                authorities.removeValue(forKey: key)
            }
        }
    }

    @MainActor
    mutating func register<R: Route>(
        _ authority: RouterAuthority<R>,
        for routeType: R.Type
    ) {
        self[routeType] = authority
    }
}

extension EnvironmentValues {
    @Entry var routerEnvironment: RouterEnvironment?
}

extension View {
    /// Publishes one stable read-only scope from the canonical store.
    @MainActor
    func routerAuthority<R: Route>(
        _ scope: RouterScope<R>,
        for routeType: R.Type
    ) -> some View {
        transformEnvironment(\.routerEnvironment) { environment in
            var resolved = environment ?? RouterEnvironment()
            resolved.register(RouterAuthority(scope: scope), for: routeType)
            environment = resolved
        }
    }
}
