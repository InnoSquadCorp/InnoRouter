// Store-owned execution identities. These are never persisted and do not drive
// native scene open/close operations.
import Foundation
import Observation

import InnoRouterCore

package enum RouterScopeLifetimeMutation: Sendable {
    case reconcile
    case replaceAll
    case replaceSubtree(RouterScopePath)

    var replacesOwnership: Bool {
        if case .reconcile = self { return false }
        return true
    }

    func replaces(_ path: RouterScopePath) -> Bool {
        switch self {
        case .reconcile: false
        case .replaceAll: true
        case .replaceSubtree(let root):
            root.domain == path.domain && path.components.starts(with: root.components)
        }
    }
}

struct RouterScopeRuntimeLifetime<R: Route> {
    enum Kind: Equatable { case stack, container(RouterContainerStyle) }
    let token: UUID
    let kind: Kind
    let sceneRoute: R?
}

@MainActor
@Observable
final class RouterScopeLifetimeObservation {
    var token: UUID?
    init(_ token: UUID?) { self.token = token }
}

extension RouterStore {
    /// Captures one current runtime authority. Absence is permanently invalid.
    func scopeLifetimeToken(at path: RouterScopePath) -> UUID? {
        scopeLifetimes[path]?.token
    }

    func observesScopeLifetime(at path: RouterScopePath) -> UUID? {
        let observation: RouterScopeLifetimeObservation
        if let existing = scopeLifetimeObservations[path] {
            observation = existing
        } else {
            observation = RouterScopeLifetimeObservation(scopeLifetimeToken(at: path))
            scopeLifetimeObservations[path] = observation
        }
        // Register the dependency, but read authority from the canonical map.
        // Observation callbacks run during willSet, when the observable slot
        // can still hold the previous incarnation's token.
        _ = observation.token
        return scopeLifetimeToken(at: path)
    }

    func scopeLifetimePrecondition(at path: RouterScopePath) -> RouterRequestPrecondition<R> {
        let token = scopeLifetimeToken(at: path)
        return { [weak self] _ in
            guard let token, self?.scopeLifetimeToken(at: path) == token else {
                return .mutation(.expiredScope(path))
            }
            return nil
        }
    }

    /// Installs the new graph's runtime identities and returns presentations
    /// whose old result ownership ended, including same-ID replacements.
    func updateScopeLifetimes(
        after state: RouterState<R>,
        mutation: RouterScopeLifetimeMutation,
        requestRootID: RouterTransitionID
    ) -> Set<UUID> {
        let previousScopes = scopeLifetimes
        let previousPresentations = presentationLifetimes
        let nextScopes = Self.makeScopeLifetimes(
            in: state, previous: previousScopes, mutation: mutation
        )
        let nextPresentations = Self.makePresentationLifetimes(
            in: state, scopes: nextScopes, previous: previousPresentations
        )
        // Install both maps before publishing any observable lifetime slot.
        // Synchronous observers may capture either kind of authority in willSet.
        scopeLifetimes = nextScopes
        presentationLifetimes = nextPresentations
        // Only the request lineage that registered a typed waiter can activate
        // it. Install this private authority before any observable publication.
        for (id, waiter) in presentationWaiters where waiter.activatedToken() == nil {
            if waiter.showRequestRootID == requestRootID,
               let lifetime = nextPresentations[id], lifetime.scope == waiter.ownerPath {
                waiter.activate(lifetime.token)
            }
        }
        var retired = Set(previousPresentations.compactMap { id, lifetime -> UUID? in
            nextPresentations[id]?.token == lifetime.token ? nil : id
        })
        for (id, waiter) in presentationWaiters where !waiter.lifetimeIsCurrent() {
            retired.insert(id)
        }
        updatePresentationLifetimeObservations()
        for (path, observation) in scopeLifetimeObservations {
            let current = scopeLifetimeToken(at: path)
            if observation.token != current { observation.token = current }
        }
        return retired
    }

    static func makeScopeLifetimes(
        in state: RouterState<R>,
        previous: [RouterScopePath: RouterScopeRuntimeLifetime<R>] = [:],
        mutation: RouterScopeLifetimeMutation = .reconcile
    ) -> [RouterScopePath: RouterScopeRuntimeLifetime<R>] {
        typealias Entry = (path: RouterScopePath, node: RouterNode<R>, parent: RouterScopePath?, sceneRoute: R?)
        var pending: [Entry] = [(.root, state.root, nil, nil)]
        pending += state.windows.map { (.window($0.id), $0.node, nil, $0.route) }
        if let space = state.immersiveSpace {
            pending.append((.immersiveSpace(space.id), space.node, nil, space.route))
        }
        var result: [RouterScopePath: RouterScopeRuntimeLifetime<R>] = [:]
        while let entry = pending.popLast() {
            let kind: RouterScopeRuntimeLifetime<R>.Kind
            switch entry.node {
            case .stack(let stack):
                kind = .stack
                if let presentation = stack.presentation {
                    pending.append((entry.path.appendingPresentation(presentation.id), presentation.node, entry.path, nil))
                }
            case .container(let container):
                kind = .container(container.style)
                pending += container.branches.map { (entry.path.appending($0.id), $0.node, entry.path, nil) }
            }
            let old = previous[entry.path]
            let sameParent = entry.parent.map { result[$0]?.token == previous[$0]?.token } ?? true
            let retainsIdentity = !mutation.replaces(entry.path) && sameParent
                && old?.kind == kind && old?.sceneRoute == entry.sceneRoute
            result[entry.path] = .init(
                token: retainsIdentity ? old?.token ?? UUID() : UUID(),
                kind: kind,
                sceneRoute: entry.sceneRoute
            )
        }
        return result
    }
}

public extension RouterStore {
    /// Replaces one subtree with a new runtime ownership lifetime, even when
    /// its value is unchanged. Unrelated scopes and native scenes stay alive.
    ///
    /// In contrast, ordinary `.apply` reconciles retained paths and node kinds.
    /// Use this owning-Store operation for intentional same-shaped replacement.
    func replaceSubtree(
        at path: RouterScopePath = .root,
        with node: RouterNode<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        let resourceBudget = self.resourceBudget
        let preparation: RouterRequestPreparationBuilder<R> = { state in
            prepareRouterFeaturePlan(node: node, at: path, in: state, resourceBudget: resourceBudget)
        }
        let submittedAction: RouterAction<R> = switch preparation(state) {
        case .action(let action): action
        case .rejected: .apply(.init(state: state))
        }
        return await perform(
            submittedAction,
            context: context,
            expectedRevision: nil,
            bypassesPolicies: false,
            lifetimeMutation: .replaceSubtree(path),
            executionPrecondition: scopeLifetimePrecondition(at: path),
            executionPreparation: preparation,
            deferredResumePreparation: { state, _ in preparation(state) }
        )
    }
}

extension RouterStore {
    /// Returns the stable read-only projection for `path`.
    public func scope(at path: RouterScopePath = .root) -> RouterScope<R> {
        compactDeadScopes()
        let token = observesScopeLifetime(at: path)
        if let scope = scopes[path]?.value, scope.matchesCapturedLifetime(token) {
            return scope
        }
        let scope = RouterScope(
            path: path,
            node: state.node(at: path),
            store: self,
            lifetimeToken: token
        )
        scopes[path] = WeakRouterScope(scope)
        return scope
    }
}
