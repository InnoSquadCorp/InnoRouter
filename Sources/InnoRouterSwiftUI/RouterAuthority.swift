import Foundation

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
    var resourceBudget: RouterResourceBudget? { get }
    var observedPath: [R] { get }
    var observedSceneRootRoute: R? { get }
    var observedPresentation: RouterPresentation<R>? { get }
    var observedPresentationFamily: RouterPresentationFamily<R>? { get }
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
    func performFeatureAction(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R>
    func performFeaturePlan(
        _ node: RouterNode<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
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
    func presentFeature<Value: Sendable>(
        _ route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions,
        expecting: Value.Type,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value>
    func presentFeature<Value: Sendable>(
        _ request: RouterTransientPresentationRequest<Value>,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterPresentationOutcome<Value>
    func presentationHandle() -> RouterPresentationHandle?
    func performPresentationAction(
        _ action: RouterAction<R>, using handle: RouterPresentationHandle,
        context: RouterTransitionContext, features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R>
    func finishPresentation<Value: Sendable>(returning value: Value) async throws
    func finishPresentation<Value: Sendable>(
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws
    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value
    ) async throws
    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws
    func finishFeaturePresentation<Value: Sendable>(
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws
    func finishFeaturePresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws
    func reject(_ reason: RouterRejectionReason) -> RouterOutcome<R>
    func reportPlatformAdaptation(_ adaptation: RouterPlatformAdaptation)
    func rebased<Root: Route>(
        replacing owner: RouterScope<Root>, with replacement: RouterAuthority<Root>
    ) -> RouterAuthority<R>?
}

package func prepareRouterFeaturePlan<R: Route>(
    node: RouterNode<R>,
    at path: RouterScopePath,
    in state: RouterState<R>,
    resourceBudget: RouterResourceBudget = .provisional
) -> RouterDeferredResumePreparation<R> {
    do {
        let target = try state.replacingNode(node, at: path, resourceBudget: resourceBudget)
        return .action(.apply(RouterPlan(state: target)))
    } catch let failure as RouterResourceLimitFailure {
        return .rejected(.resourceLimit(failure))
    } catch let error as RouterStateValidationError {
        return .rejected(.mutation(.invalidTargetState(error)))
    } catch let error as RouterMutationError {
        return .rejected(.mutation(error))
    } catch {
        return .rejected(.mutation(.incompatibleNavigationTopology(path)))
    }
}

/// The one canonical authority published for a route type.
struct RouterAuthority<R: Route>: Sendable {
    let base: any RouterAuthorityProtocol<R>
    let enclosingPresentation: RouterEnclosingPresentationEndpoint<R>?

    init(scope: RouterScope<R>, enclosingPresentation: RouterEnclosingPresentationEndpoint<R>? = nil) {
        self.base = scope
        self.enclosingPresentation = enclosingPresentation
    }

    init(base: some RouterAuthorityProtocol<R>, enclosingPresentation: RouterEnclosingPresentationEndpoint<R>? = nil) {
        self.base = base
        self.enclosingPresentation = enclosingPresentation
    }
}

@MainActor
private protocol RouterAuthorityRebaseBox: Sendable {
    func rebased<Root: Route>(
        replacing owner: RouterScope<Root>, with replacement: RouterAuthority<Root>
    ) -> ErasedRouterAuthority?
}

@MainActor
private final class TypedRouterAuthorityRebaseBox<R: Route>: RouterAuthorityRebaseBox {
    let authority: RouterAuthority<R>
    init(_ authority: RouterAuthority<R>) { self.authority = authority }
    func rebased<Root: Route>(
        replacing owner: RouterScope<Root>, with replacement: RouterAuthority<Root>
    ) -> ErasedRouterAuthority? {
        authority.base.rebased(replacing: owner, with: replacement).map(ErasedRouterAuthority.init)
    }
}

@MainActor
private final class ErasedRouterAuthority: Sendable {
    private let value: Any
    private let rebaseBox: any RouterAuthorityRebaseBox

    init<R: Route>(_ authority: RouterAuthority<R>) {
        value = authority
        rebaseBox = TypedRouterAuthorityRebaseBox(authority)
    }

    func authority<R: Route>(for routeType: R.Type) -> RouterAuthority<R>? {
        _ = routeType
        return value as? RouterAuthority<R>
    }

    func rebased<Root: Route>(
        replacing owner: RouterScope<Root>, with replacement: RouterAuthority<Root>
    ) -> ErasedRouterAuthority? {
        rebaseBox.rebased(replacing: owner, with: replacement)
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

    /// Rebuilds the existing finite feature-parent chains over a new rendered
    /// scope. The native host route type itself becomes the direct replacement,
    /// just like ordinary host environment registration; other route types keep
    /// their feature chains. Unrelated Stores/scopes remain untouched; no type dependency graph
    /// or fresh Store is inferred from the navigation value.
    @MainActor
    mutating func rebase<Root: Route>(
        replacing owner: RouterScope<Root>, with replacement: RouterAuthority<Root>
    ) {
        let rootKey = ObjectIdentifier(Root.self)
        for (key, authority) in authorities where key != rootKey {
            if let rebased = authority.rebased(replacing: owner, with: replacement) {
                authorities[key] = rebased
            }
        }
        authorities[rootKey] = ErasedRouterAuthority(replacement)
    }

    @MainActor
    mutating func register<R: Route>(
        _ authority: RouterAuthority<R>,
        for routeType: R.Type
    ) {
        self[routeType] = authority
    }
}
