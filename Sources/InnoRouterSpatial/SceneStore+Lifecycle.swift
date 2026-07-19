// MARK: - SceneStore+Lifecycle.swift
// InnoRouterSpatial — SwiftUI scene-root lifecycle coordination.

#if os(visionOS)

import Foundation

import InnoRouterCore

extension SceneStore {
    @discardableResult
    internal func registerSceneLifecycle(
        route: R,
        scenes: SceneRegistry<R>,
        instanceID: UUID?,
        token: UUID
    ) -> ScenePresentation<R> {
        guard let declaration = scenes.declaration(for: route) else {
            preconditionFailure(
                "Scene lifecycle registration requires a declared route: \(String(describing: route))"
            )
        }

        if let registered = lifecycleRegistry.presentation(for: token),
           declaration.matches(registered),
           instanceID == nil || registered.id == instanceID {
            return registered
        }

        let presentation = state.presentationForAttachment(
            declaration: declaration,
            instanceID: instanceID
        )
        registerSceneLifecycle(presentation, token: token)
        return presentation
    }

    internal func registerSceneLifecycle(
        _ presentation: ScenePresentation<R>,
        token: UUID
    ) {
        let change = lifecycleRegistry.register(
            presentation,
            token: token,
            activeScenes: state.activeScenes
        )
        guard change.presentationToDetach != nil || change.presentationToAttach != nil else {
            return
        }

        if let presentationToDetach = change.presentationToDetach {
            state.detach(presentationToDetach)
        }
        if let presentationToAttach = change.presentationToAttach {
            state.attach(presentationToAttach)
        }
        syncFromState()
    }

    internal func unregisterSceneLifecycle(_ token: UUID) {
        guard let presentation = lifecycleRegistry.unregister(token) else {
            return
        }

        state.detach(presentation)
        syncFromState()
    }
}

#endif
