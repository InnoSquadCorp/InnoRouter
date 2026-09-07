// MARK: - RouterStore+SceneReconciliation.swift
// InnoRouterSwiftUI - scene catalog validation and native-failure repair
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore

extension RouterStore {
    func updateImmersiveSpaceLifecycleToken(
        before: RouterState<R>,
        after: RouterState<R>
    ) {
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

    /// Repairs canonical scene state after the native system reports that a
    /// committed open could not be represented. The repair still uses the
    /// reducer, revision check, commit, and event pipeline, but policies cannot
    /// preserve a scene that the operating system failed to create.
    package func reconcileSceneSystemFailure(
        _ action: RouterAction<R>,
        expectedRevision: UInt64
    ) async -> RouterOutcome<R> {
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
                bypassesPolicies: true
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
