// MARK: - SceneIntentResolver.swift
// InnoRouterSpatial — spatial intent validation and dispatch planning.

import Foundation

import InnoRouterCore

internal enum SceneDispatchPlan<R: Route>: Equatable {
    case openWindow(id: String, value: UUID, presentation: ScenePresentation<R>)
    case openImmersive(id: String, presentation: ScenePresentation<R>)
    case dismissWindow(id: String, value: UUID, presentation: ScenePresentation<R>)
    case dismissImmersive(presentation: ScenePresentation<R>)
    case reject(SceneIntent<R>, reason: SceneRejectionReason)
}

internal extension SceneDispatchPlan {
    /// Whether a fallback anchor attached to `anchorPresentation` is
    /// allowed to execute this plan.
    ///
    /// Dismissals and resolver-level rejections are always serviceable
    /// — they don't need cross-scene authority. Opens are only
    /// serviceable when they target the anchor's own scene declaration,
    /// so a theatre anchor cannot silently commit a main-window open.
    /// A value-based window can open another instance of its own
    /// declaration; instance UUIDs identify windows, not dispatch authority.
    func isServiceableByFallback(
        attachedTo anchorPresentation: ScenePresentation<R>,
        declaredIn scenes: SceneRegistry<R>
    ) -> Bool {
        switch self {
        case .openWindow(_, _, let presentation),
             .openImmersive(_, let presentation):
            guard
                let anchorDeclaration = scenes.declaration(for: anchorPresentation.route),
                anchorDeclaration.matches(anchorPresentation),
                let targetDeclaration = scenes.declaration(for: presentation.route),
                targetDeclaration.matches(presentation)
            else {
                return false
            }

            return anchorDeclaration == targetDeclaration
        case .dismissWindow, .dismissImmersive, .reject:
            return true
        }
    }
}

internal struct SceneIntentResolver<R: Route> {
    internal let scenes: SceneRegistry<R>

    internal init(scenes: SceneRegistry<R>) {
        self.scenes = scenes
    }

    internal func resolve(
        _ intent: SceneIntent<R>,
        state: SceneStoreSnapshot<R>
    ) -> SceneDispatchPlan<R> {
        switch intent {
        case .open(let presentation):
            resolveOpen(presentation)
        case .dismissImmersive:
            resolveDismissImmersive(state: state)
        case .dismissWindow(let presentation):
            resolveDismissWindow(presentation, state: state)
        }
    }

    private func resolveOpen(
        _ presentation: ScenePresentation<R>
    ) -> SceneDispatchPlan<R> {
        let intent = SceneIntent<R>.open(presentation)

        guard let declaration = scenes.declaration(for: presentation.route) else {
            return .reject(intent, reason: .sceneNotDeclared)
        }
        guard declaration.matches(presentation) else {
            return .reject(intent, reason: .sceneDeclarationMismatch)
        }

        switch presentation {
        case .window, .volumetric:
            return .openWindow(id: declaration.id, value: presentation.id, presentation: presentation)
        case .immersive:
            return .openImmersive(id: declaration.id, presentation: presentation)
        }
    }

    private func resolveDismissImmersive(
        state: SceneStoreSnapshot<R>
    ) -> SceneDispatchPlan<R> {
        let intent = SceneIntent<R>.dismissImmersive

        guard let activeImmersive = state.activeImmersive else {
            return .reject(
                intent,
                reason: state.hasActiveScenes ? .activeSceneMismatch : .nothingActive
            )
        }
        guard let declaration = scenes.declaration(for: activeImmersive.route) else {
            return .reject(intent, reason: .sceneNotDeclared)
        }
        guard declaration.matches(activeImmersive) else {
            return .reject(intent, reason: .sceneDeclarationMismatch)
        }

        return .dismissImmersive(presentation: activeImmersive)
    }

    private func resolveDismissWindow(
        _ presentation: ScenePresentation<R>,
        state: SceneStoreSnapshot<R>
    ) -> SceneDispatchPlan<R> {
        let intent = SceneIntent<R>.dismissWindow(presentation)

        guard let activeWindow = state.windowPresentation(id: presentation.id) else {
            return .reject(intent, reason: .sceneInstanceNotActive)
        }
        guard activeWindow == presentation else {
            return .reject(intent, reason: .sceneInstanceNotActive)
        }
        guard let declaration = scenes.declaration(for: activeWindow.route) else {
            return .reject(intent, reason: .sceneNotDeclared)
        }
        guard declaration.matches(activeWindow) else {
            return .reject(intent, reason: .sceneDeclarationMismatch)
        }

        return .dismissWindow(id: declaration.id, value: activeWindow.id, presentation: activeWindow)
    }
}
