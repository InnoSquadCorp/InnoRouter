import InnoRouterCore

/// Captured completion authority for the nearest enclosing navigation modal.
/// Navigation keeps using the rendered child's regular RouterAuthority. This
/// endpoint can only dismiss, change a detent, or finish its captured owner.
/// It owns no Store or navigation value and cannot acquire a later incarnation.
@MainActor
struct RouterEnclosingPresentationEndpoint<R: Route>: Sendable {
    private let base: any RouterEnclosingPresentationEndpointProtocol<R>

    init(
        owner: RouterScope<R>,
        renderedChild: RouterScope<R>,
        handle: RouterPresentationHandle
    ) {
        base = RouterDirectEnclosingPresentationEndpoint(
            owner: owner, renderedChild: renderedChild, handle: handle
        )
    }

    private init(base: some RouterEnclosingPresentationEndpointProtocol<R>) {
        self.base = base
    }

    var isCurrent: Bool { base.isCurrent }

    /// Only the rendered child is projected. Its enclosing owner may contain
    /// unrelated application routes that do not belong to this feature.
    func projected<Child: Route>(
        using mapping: RouterFeatureMapping<R, Child>
    ) -> RouterEnclosingPresentationEndpoint<Child> {
        .init(base: RouterFeatureEnclosingPresentationEndpoint(parent: base, mapping: mapping))
    }

    func dismiss(
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await base.perform(.dismiss, context: context, features: [], executionPrecondition: nil)
    }

    func setPresentationDetent(
        _ detent: RouterPresentationDetent,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await base.perform(.detent(detent), context: context, features: [], executionPrecondition: nil)
    }

    func finishPresentation<Value: Sendable>(returning value: Value) async throws {
        try await base.finish(nil, returning: value, features: [], executionPrecondition: nil)
    }

    func finishPresentation<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>,
        returning value: Value
    ) async throws {
        try await base.finish(request, returning: value, features: [], executionPrecondition: nil)
    }
}

private enum RouterEnclosingPresentationAction {
    case dismiss
    case detent(RouterPresentationDetent)

    func action<R: Route>() -> RouterAction<R> {
        switch self {
        case .dismiss: .dismissPresentation
        case .detent(let value): .setPresentationDetent(value)
        }
    }
}

@MainActor
private protocol RouterEnclosingPresentationEndpointProtocol<R>: AnyObject, Sendable {
    associatedtype R: Route

    var isCurrent: Bool { get }
    var renderedNode: RouterNode<R>? { get }

    /// Child location in returned outcome snapshots. Direct endpoints retain
    /// canonical Store outcomes; feature endpoints return local projections.
    var outcomeScopePath: RouterScopePath { get }

    /// Preconditions always inspect rendered-child-local state.
    func perform(
        _ action: RouterEnclosingPresentationAction,
        context: RouterTransitionContext,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R>

    func finish<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>?,
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws
}

@MainActor
private final class RouterDirectEnclosingPresentationEndpoint<R: Route>:
    RouterEnclosingPresentationEndpointProtocol {
    private let owner: RouterScope<R>
    private let renderedChild: RouterScope<R>
    private let handle: RouterPresentationHandle
    private let capturedPrecondition: RouterRequestPrecondition<R>
    private let captureWasValid: Bool

    init(owner: RouterScope<R>, renderedChild: RouterScope<R>, handle: RouterPresentationHandle) {
        self.owner = owner
        self.renderedChild = renderedChild
        self.handle = handle
        let boundary = handle.scope.appendingPresentation(handle.id)
        let childPath = renderedChild.path
        let relative = childPath.components.dropFirst(boundary.components.count)
        let sameStore = owner.store != nil && owner.store === renderedChild.store
        let nearest = childPath.domain == boundary.domain
            && childPath.components.starts(with: boundary.components)
            && !relative.contains { if case .presentation = $0 { true } else { false } }
        let validCapture = sameStore && handle.scope == owner.path && nearest
        captureWasValid = validCapture
        let presentation = owner.store?.presentationHandlePrecondition(handle)
        let presentingOwner = owner.combinedExecutionPrecondition(nil)
        let child = renderedChild.combinedExecutionPrecondition(nil)
        capturedPrecondition = { state in
            guard validCapture, let presentation else {
                return .mutation(.expiredScope(childPath))
            }
            return presentation(state) ?? presentingOwner?(state) ?? child?(state)
        }
    }

    var isCurrent: Bool {
        guard captureWasValid, owner.presentationHandle() == handle,
              let store = owner.store else { return false }
        let current = store.observesScopeLifetime(at: renderedChild.path)
        return current != nil && renderedChild.matchesCapturedLifetime(current)
    }

    var renderedNode: RouterNode<R>? { isCurrent ? renderedChild.node : nil }
    var outcomeScopePath: RouterScopePath { renderedChild.path }

    private func precondition(
        _ supplied: RouterRequestPrecondition<R>?
    ) -> RouterRequestPrecondition<R> {
        let captured = capturedPrecondition
        let path = renderedChild.path
        return { state in
            if let rejection = captured(state) { return rejection }
            guard let supplied else { return nil }
            guard let node = state.node(at: path), let projected = try? RouterState(root: node) else {
                return .mutation(.expiredScope(path))
            }
            return supplied(projected)
        }
    }

    func perform(
        _ action: RouterEnclosingPresentationAction,
        context: RouterTransitionContext,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterOutcome<R> {
        let check = precondition(executionPrecondition)
        // The same captured check is retained by the queue/policy/deferral
        // pipeline. This eager check does not substitute for later admission.
        if let state = owner.store?.state, let rejection = check(state) {
            return owner.reject(rejection)
        }
        return await owner.performPresentationAction(
            action.action(), using: handle, context: context, features: features,
            executionPrecondition: check
        )
    }

    func finish<Value: Sendable>(
        _ request: RouterPresentationRequest<R, Value>?,
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async throws {
        let check = precondition(executionPrecondition)
        guard let state = owner.store?.state else {
            throw RouterPresentationCompletionError.dismissalRejected(.mutation(.expiredScope(owner.path)))
        }
        // Validate before looking up or preparing a result waiter, including
        // before the typed route-match check in the owning Store.
        if let rejection = check(state) {
            throw RouterPresentationCompletionError.dismissalRejected(rejection)
        }
        if let request {
            if features.isEmpty {
                try await owner.finishPresentation(request, returning: value, executionPrecondition: check)
            } else {
                try await owner.finishFeaturePresentation(
                    request, returning: value, features: features, executionPrecondition: check
                )
            }
        } else if features.isEmpty {
            try await owner.finishPresentation(returning: value, executionPrecondition: check)
        } else {
            try await owner.finishFeaturePresentation(
                returning: value, features: features, executionPrecondition: check
            )
        }
    }
}

@MainActor
private final class RouterFeatureEnclosingPresentationEndpoint<Parent: Route, Child: Route>:
    RouterEnclosingPresentationEndpointProtocol {
    private let parent: any RouterEnclosingPresentationEndpointProtocol<Parent>
    private let mapping: RouterFeatureMapping<Parent, Child>

    init(
        parent: any RouterEnclosingPresentationEndpointProtocol<Parent>,
        mapping: RouterFeatureMapping<Parent, Child>
    ) {
        self.parent = parent
        self.mapping = mapping
    }

    var isCurrent: Bool { renderedNode != nil }
    var renderedNode: RouterNode<Child>? {
        parent.renderedNode.flatMap { try? mapping.project($0) }
    }
    var outcomeScopePath: RouterScopePath { .root }

    private var feature: RouterFeatureCatalogEntry {
        .init(id: mapping.id, namespace: mapping.namespace, childRouteTypeName: String(describing: Child.self))
    }

    private func precondition(
        _ supplied: RouterRequestPrecondition<Child>?
    ) -> RouterRequestPrecondition<Parent> {
        let mapping = mapping
        return { state in
            guard let projected = try? mapping.projectState(from: state.root) else {
                return .featureProjection(.routeMismatch(namespace: mapping.namespace))
            }
            return supplied?(projected)
        }
    }

    func perform(
        _ action: RouterEnclosingPresentationAction,
        context: RouterTransitionContext,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<Child>?
    ) async -> RouterOutcome<Child> {
        let outcome = await parent.perform(
            action, context: context, features: [feature] + features,
            executionPrecondition: precondition(executionPrecondition)
        )
        let path = parent.outcomeScopePath
        return mapEnclosingPresentationOutcome(outcome) { state in
            state.node(at: path).flatMap { try? mapping.projectState(from: $0) }
        }
    }

    func finish<Value: Sendable>(
        _ request: RouterPresentationRequest<Child, Value>?,
        returning value: Value,
        features: [RouterFeatureCatalogEntry],
        executionPrecondition: RouterRequestPrecondition<Child>?
    ) async throws {
        let embedded = request.map {
            RouterPresentationRequest<Parent, Value>(
                route: mapping.route.embed($0.route), style: $0.style, options: $0.options
            )
        }
        try await parent.finish(
            embedded, returning: value, features: [feature] + features,
            executionPrecondition: precondition(executionPrecondition)
        )
    }
}

/// Empty local state represents the removed rendered subtree after dismissal;
/// it is an outcome projection, never another canonical navigation state.
/// A rejected request may also have lost its child/feature projection; the empty
/// local snapshot then carries the original rejection, ID, and revision without
/// suggesting that the Store became empty. Successful unchanged/deferred paths
/// retain the checked child projection. Projection must not turn an already
/// committed dismissal into a rejection.
@MainActor
private func mapEnclosingPresentationOutcome<Parent: Route, Child: Route>(
    _ outcome: RouterOutcome<Parent>,
    project: (RouterState<Parent>) -> RouterState<Child>?
) -> RouterOutcome<Child> {
    switch outcome {
    case .applied(let id, let before, let after, let revision):
        .applied(id: id, before: project(before) ?? .rootStack, after: project(after) ?? .rootStack, revision: revision)
    case .unchanged(let id, let state, let revision):
        .unchanged(id: id, state: project(state) ?? .rootStack, revision: revision)
    case .deferred(let id, let state, let revision, let deferral):
        .deferred(id: id, state: project(state) ?? .rootStack, revision: revision, deferral: deferral)
    case .rejected(let id, let state, let revision, let reason):
        .rejected(id: id, state: project(state) ?? .rootStack, revision: revision, reason: reason)
    }
}
