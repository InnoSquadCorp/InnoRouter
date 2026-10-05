import Foundation
import Observation

import InnoRouterCore

/// Captured authority for one presentation incarnation in its owning Store.
///
/// Capture a handle during rendering, then use it when a button or dismissal
/// callback fires. A logical presentation ID alone cannot distinguish a later
/// replacement. Handles cannot be constructed by callers or persisted.
public struct RouterPresentationHandle: Hashable, Sendable {
    public let id: UUID
    public let scope: RouterScopePath
    fileprivate let token: UUID
}

/// Derived runtime bookkeeping; presentation values remain in RouterState.
struct RouterPresentationRuntimeLifetime {
    let token: UUID
    let scope: RouterScopePath
    let kind: RouterPresentationFamilyKind
    let ownerToken: UUID
    let childToken: UUID?
}

/// One observed presentation authority per live stack owner, including absence.
@MainActor
@Observable
final class RouterPresentationLifetimeObservation {
    enum Value: Equatable {
        case current(UUID?)
        case retired
    }

    var value: Value
    init(_ token: UUID?) { self.value = .current(token) }
}

@MainActor
extension RouterStore {
    static func makePresentationLifetimes(
        in state: RouterState<R>,
        scopes: [RouterScopePath: RouterScopeRuntimeLifetime<R>],
        previous: [UUID: RouterPresentationRuntimeLifetime] = [:]
    ) -> [UUID: RouterPresentationRuntimeLifetime] {
        var pending: [(RouterScopePath, RouterNode<R>)] = [(.root, state.root)]
        pending += state.windows.map { (.window($0.id), $0.node) }
        if let space = state.immersiveSpace {
            pending.append((.immersiveSpace(space.id), space.node))
        }
        var result: [UUID: RouterPresentationRuntimeLifetime] = [:]
        while let (path, node) = pending.popLast() {
            switch node {
            case .container(let container):
                pending += container.branches.map { (path.appending($0.id), $0.node) }
            case .stack(let stack):
                guard let family = stack.presentationFamily,
                      let ownerToken = scopes[path]?.token else { continue }
                let childToken: UUID?
                if case .navigation(let navigation) = family {
                    let childPath = path.appendingPresentation(navigation.id)
                    childToken = scopes[childPath]?.token
                    pending.append((childPath, navigation.node))
                } else {
                    // A transient has display metadata, never a child node.
                    childToken = nil
                }
                let old = previous[family.id]
                // Core enforces immutable family identity for retained IDs.
                // Only the navigation child root affects its owner's lifetime;
                // edits deeper in that child must not retire the outer modal.
                let retained = old?.scope == path && old?.kind == family.kind
                    && old?.ownerToken == ownerToken && old?.childToken == childToken
                result[family.id] = .init(
                    token: retained ? old?.token ?? UUID() : UUID(),
                    scope: path, kind: family.kind,
                    ownerToken: ownerToken, childToken: childToken
                )
            }
        }
        return result
    }

    /// Captures the currently presented family's runtime authority, if any.
    public func presentationHandle(
        at path: RouterScopePath = .root
    ) -> RouterPresentationHandle? {
        // Only live stack owners can present. Arbitrary missing paths and
        // container reads must not accumulate observation slots.
        guard scopeLifetimes[path]?.kind == .stack else { return nil }
        let current = presentationLifetimes.first(where: { $0.value.scope == path })
        let observation: RouterPresentationLifetimeObservation
        if let existing = presentationLifetimeObservations[path] {
            observation = existing
        } else {
            observation = RouterPresentationLifetimeObservation(current?.value.token)
            presentationLifetimeObservations[path] = observation
        }
        // Register only this owner's presentation dependency. Global state and
        // owner scope identity do not describe child-root-only replacement.
        // Authority comes from the installed registry, because an observation
        // callback runs in willSet while its slot can still hold the old token.
        _ = observation.value
        guard let (id, lifetime) = current,
              scopeLifetimeToken(at: path) == lifetime.ownerToken else { return nil }
        return .init(id: id, scope: path, token: lifetime.token)
    }

    /// Publishes only after both canonical lifetime registries are installed.
    func updatePresentationLifetimeObservations() {
        let tokens = Dictionary(uniqueKeysWithValues: presentationLifetimes.values.map {
            ($0.scope, $0.token)
        })
        var retired: [RouterPresentationLifetimeObservation] = []
        var changed: [(RouterPresentationLifetimeObservation, UUID?)] = []
        for (path, observation) in presentationLifetimeObservations {
            guard scopeLifetimes[path]?.kind == .stack else {
                presentationLifetimeObservations.removeValue(forKey: path)
                retired.append(observation)
                continue
            }
            let current = tokens[path]
            if observation.value != .current(current) { changed.append((observation, current)) }
        }
        // Retire every removed owner before callbacks can inspect the cache.
        // Absence and retirement differ, so observers of empty owners are also
        // notified instead of remaining subscribed to a permanently dead slot.
        for observation in retired { observation.value = .retired }
        for (observation, token) in changed { observation.value = .current(token) }
    }

    /// An absent capture remains invalid even if that ID appears later.
    func presentationRuntimePrecondition(
        id: UUID,
        at path: RouterScopePath
    ) -> RouterRequestPrecondition<R> {
        let lifetime = presentationLifetimes[id]
        let token = lifetime?.scope == path ? lifetime?.token : nil
        return presentationRuntimePrecondition(id: id, at: path, token: token)
    }

    func presentationHandlePrecondition(
        _ handle: RouterPresentationHandle
    ) -> RouterRequestPrecondition<R> {
        presentationRuntimePrecondition(id: handle.id, at: handle.scope, token: handle.token)
    }

    private func presentationRuntimePrecondition(
        id: UUID,
        at path: RouterScopePath,
        token: UUID?
    ) -> RouterRequestPrecondition<R> {
        let identity = Self.presentationIdentityPrecondition(id: id, at: path)
        return { [weak self] state in
            if let rejection = identity(state) { return rejection }
            guard let self, let token,
                  let lifetime = self.presentationLifetimes[id],
                  lifetime.scope == path, lifetime.token == token,
                  self.scopeLifetimeToken(at: path) == lifetime.ownerToken else {
                return .mutation(.expiredPresentation(id, scope: path))
            }
            return nil
        }
    }

    /// Selects a declared action only while the captured incarnation is alive.
    public func selectPresentationAction(
        _ actionID: RouterPresentationActionID,
        using handle: RouterPresentationHandle,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await perform(
            .selectPresentationAction(presentationID: handle.id, actionID: actionID).inScope(handle.scope),
            context: context, expectedRevision: nil, bypassesPolicies: false,
            executionPrecondition: presentationHandlePrecondition(handle)
        )
    }

    /// Dismisses only the incarnation that was captured, through normal policies.
    public func dismissPresentation(
        using handle: RouterPresentationHandle,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await perform(
            .dismissPresentation.inScope(handle.scope),
            context: context, expectedRevision: nil, bypassesPolicies: false,
            executionPrecondition: presentationHandlePrecondition(handle)
        )
    }
}
