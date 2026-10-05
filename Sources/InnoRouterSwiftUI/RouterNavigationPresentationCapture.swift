import InnoRouterCore

/// Immutable native-render input for one navigation presentation incarnation.
/// It forwards to the existing Store through captured scopes; it owns neither
/// navigation state nor a second lifetime registry.
@MainActor
struct RouterNavigationPresentationCapture<R: Route>: Identifiable, Sendable {
    let owner: RouterScope<R>
    let child: RouterScope<R>
    nonisolated let handle: RouterPresentationHandle

    nonisolated var id: RouterPresentationHandle { handle }

    init?(owner: RouterScope<R>) {
        // Observe the narrow projection, but obtain the value from the Store.
        // During willSet the projection may still describe its previous value.
        _ = owner.observedPresentation
        guard let store = owner.store, owner.matchesCurrentLifetime,
              case .stack(let stack) = store.state.node(at: owner.path),
              let presentation = stack.presentation,
              let handle = owner.presentationHandle(), handle.id == presentation.id else { return nil }
        let child = store.scope(at: owner.path.appendingPresentation(handle.id))
        guard child.matchesCurrentLifetime else { return nil }
        self.owner = owner
        self.child = child
        self.handle = handle
    }

    var isCurrent: Bool {
        guard let store = owner.store else { return false }
        _ = store.observesScopeLifetime(at: child.path)
        return owner.matchesCurrentLifetime && child.matchesCurrentLifetime
            && owner.presentationHandle() == handle
    }

    var presentation: RouterPresentation<R>? {
        _ = owner.observedPresentation
        guard isCurrent, case .stack(let stack) = owner.store?.state.node(at: owner.path),
              let presentation = stack.presentation, presentation.id == handle.id else { return nil }
        return presentation
    }

    /// Descendants may change their local navigation authority, but cannot
    /// borrow this endpoint across another Store or a nearer presentation.
    func contains(_ scope: RouterScope<R>) -> Bool {
        guard isCurrent, scope.matchesCurrentLifetime,
              scope.store === owner.store,
              scope.path.domain == child.path.domain,
              scope.path.components.starts(with: child.path.components) else { return false }
        return !scope.path.components.dropFirst(child.path.components.count).contains {
            if case .presentation = $0 { true } else { false }
        }
    }

    func enclosingEndpoint(for scope: RouterScope<R>) -> RouterEnclosingPresentationEndpoint<R>? {
        guard contains(scope) else { return nil }
        return .init(owner: owner, renderedChild: scope, handle: handle)
    }

    var executionPrecondition: RouterRequestPrecondition<R> {
        let presentation = owner.store?.presentationHandlePrecondition(handle)
        let ownerCheck = owner.combinedExecutionPrecondition(nil)
        let childCheck = child.combinedExecutionPrecondition(nil)
        let path = child.path
        return { state in
            guard let presentation else { return .mutation(.expiredScope(path)) }
            return presentation(state) ?? ownerCheck?(state) ?? childCheck?(state)
        }
    }
}

/// Value-semantic view inheritance, not another navigation authority. Each
/// branch records the exact preceding scope so finite feature chains can be
/// rebuilt over that branch while completion keeps its captured modal owner.
@MainActor
struct RouterNavigationPresentationRenderContext<R: Route>: Sendable {
    let capture: RouterNavigationPresentationCapture<R>
    let renderedScope: RouterScope<R>

    init(capture: RouterNavigationPresentationCapture<R>) {
        self.capture = capture
        self.renderedScope = capture.owner
    }

    private init(capture: RouterNavigationPresentationCapture<R>, renderedScope: RouterScope<R>) {
        self.capture = capture
        self.renderedScope = renderedScope
    }

    func scoped(to scope: RouterScope<R>) -> Self? {
        guard capture.contains(scope) else { return nil }
        return .init(capture: capture, renderedScope: scope)
    }

    func rebase(_ environment: RouterEnvironment, onto scope: RouterScope<R>) -> RouterEnvironment? {
        guard let endpoint = capture.enclosingEndpoint(for: scope) else { return nil }
        var resolved = environment
        resolved.rebase(replacing: renderedScope, with: .init(scope: scope, enclosingPresentation: endpoint))
        return resolved
    }
}
