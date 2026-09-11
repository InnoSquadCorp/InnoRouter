// MARK: - RouterStore+SceneReconciliation.swift
// InnoRouterSwiftUI - scene catalog validation and native-failure repair
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

extension RouterStore {
    func updateSceneLifecycleTokens(
        before: RouterState<R>,
        after: RouterState<R>
    ) {
        let previousWindows = Dictionary(uniqueKeysWithValues: before.windows.map { ($0.id, $0) })
        windowLifecycleTokens = Dictionary(uniqueKeysWithValues: after.windows.map { window in
            let preservesNativeInstance = previousWindows[window.id]?.route == window.route
            return (
                window.id,
                preservesNativeInstance ? windowLifecycleTokens[window.id] ?? UUID() : UUID()
            )
        })

        let preservesNativeInstance: Bool = switch (
            before.immersiveSpace,
            after.immersiveSpace
        ) {
        case (nil, nil):
            true
        case let (.some(previous), .some(next)):
            previous.id == next.id && previous.route == next.route
        case (.none, .some), (.some, .none):
            false
        }
        guard !preservesNativeInstance else { return }
        immersiveSpaceLifecycleToken = after.immersiveSpace.map { _ in UUID() }
    }

    package func sceneRequestLifetime(at path: RouterScopePath) -> RouterSceneRequestLifetime? {
        switch path.domain {
        case .application:
            return nil
        case .window(let id):
            return windowLifecycleTokens[id].map { .window(id: id, token: $0) }
                ?? .missingWindow(id: id)
        case .immersiveSpace(let id):
            guard state.immersiveSpace?.id == id, let immersiveSpaceLifecycleToken else {
                return .missingImmersiveSpace(id: id)
            }
            return .immersiveSpace(id: id, token: immersiveSpaceLifecycleToken)
        }
    }

    package func matchesSceneRequestLifetime(_ lifetime: RouterSceneRequestLifetime) -> Bool {
        switch lifetime {
        case .window(let id, let token):
            return state.windows.contains { $0.id == id }
                && windowLifecycleTokens[id] == token
        case .immersiveSpace(let id, let token):
            return state.immersiveSpace?.id == id
                && immersiveSpaceLifecycleToken == token
        case .missingWindow, .missingImmersiveSpace:
            return false
        }
    }

    /// Captures the logical Scene lifetime at submission so package clients
    /// cannot authorize a request against a reused scope path.
    package func sceneLifetimePrecondition(
        at path: RouterScopePath
    ) -> RouterRequestPrecondition<R>? {
        guard let lifetime = sceneRequestLifetime(at: path) else { return nil }
        return { [weak self] _ in
            guard self?.matchesSceneRequestLifetime(lifetime) == true else {
                return Self.expiredSceneLifetimeReason(lifetime)
            }
            return nil
        }
    }

    static func expiredSceneLifetimeReason(
        _ lifetime: RouterSceneRequestLifetime
    ) -> RouterRejectionReason {
        switch lifetime {
        case .window(let id, _), .missingWindow(let id):
            return .mutation(.windowNotFound(id))
        case .immersiveSpace(let id, _), .missingImmersiveSpace(let id):
            return .mutation(.immersiveSpaceNotFound(id))
        }
    }

    /// Repairs canonical scene state after the native system reports that a
    /// committed open could not be represented. The repair still uses the
    /// reducer, revision check, commit, and event pipeline, but policies cannot
    /// preserve a scene that the operating system failed to create.
    package func reconcileSceneSystemFailure(
        _ action: RouterAction<R>,
        expectedRevision: UInt64? = nil,
        executionPrecondition: RouterRequestPrecondition<R>? = nil
    ) async -> RouterOutcome<R> {
        let repairIdentity: RouterSystemRepairIdentity
        switch action {
        case .dismissWindow(let id):
            guard let token = windowLifecycleTokens[id] else {
                return rejectRequest(
                    reason: .mutation(.windowNotFound(id)),
                    context: .init(source: .system),
                    action: action
                )
            }
            repairIdentity = .window(id: id, lifecycleToken: token)
        case .dismissImmersiveSpace:
            if let id = state.immersiveSpace?.id, let immersiveSpaceLifecycleToken {
                repairIdentity = .immersiveSpace(
                    id: id,
                    lifecycleToken: immersiveSpaceLifecycleToken
                )
            } else {
                return rejectRequest(
                    reason: .cancelled,
                    context: .init(source: .system),
                    action: action
                )
            }
        default:
            return rejectRequest(
                reason: .cancelled,
                context: .init(source: .system),
                action: action
            )
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return RouterOutcome<R>.rejected(
                    id: RouterTransitionID(),
                    state: .rootStack,
                    revision: 0,
                    reason: .cancelled
                )
            }
            return await perform(
                action,
                context: .init(source: .system),
                expectedRevision: expectedRevision,
                bypassesPolicies: true,
                executionPrecondition: executionPrecondition,
                systemRepairIdentity: repairIdentity
            )
        }
        return await task.value
    }

    package static func sceneCatalogValidationError(
        in state: RouterState<R>
    ) -> RouterMutationError? {
        guard R.self is any RouterSceneRoute.Type else { return nil }
        let routeType = String(describing: R.self)

        for window in state.windows {
            guard let route = window.route as? any RouterSceneRoute,
                  let scene = route.routerSceneMetadata,
                  scene.style == .window else {
                return .unsupportedScene(
                    routeType: routeType,
                    style: RouterSceneStyle.window.rawValue
                )
            }
        }

        if let immersiveSpace = state.immersiveSpace {
            guard let route = immersiveSpace.route as? any RouterSceneRoute,
                  let scene = route.routerSceneMetadata,
                  scene.style == .immersiveSpace else {
                return .unsupportedScene(
                    routeType: routeType,
                    style: RouterSceneStyle.immersiveSpace.rawValue
                )
            }
            guard scene.id == immersiveSpace.id else {
                return .sceneIdentifierMismatch(
                    expected: scene.id,
                    actual: immersiveSpace.id
                )
            }
        }

        return nil
    }
}
