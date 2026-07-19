// MARK: - SceneLifecycleRegistry.swift
// InnoRouterSpatial — ownership registry for live SwiftUI scene roots.

import Foundation

import InnoRouterCore

internal struct SceneLifecycleChange<R: Route> {
    internal let presentationToDetach: ScenePresentation<R>?
    internal let presentationToAttach: ScenePresentation<R>?

    internal static var unchanged: Self {
        Self(presentationToDetach: nil, presentationToAttach: nil)
    }
}

/// Tracks which SwiftUI host or anchor tokens own each live presentation.
///
/// Inventory mutation remains a `SceneStoreState` responsibility. This type
/// only decides when the first owner appears or the final owner disappears.
internal struct SceneLifecycleRegistry<R: Route> {
    private var presentationsByToken: [UUID: ScenePresentation<R>] = [:]

    internal func presentation(for token: UUID) -> ScenePresentation<R>? {
        presentationsByToken[token]
    }

    internal mutating func register(
        _ presentation: ScenePresentation<R>,
        token: UUID,
        activeScenes: [ScenePresentation<R>]
    ) -> SceneLifecycleChange<R> {
        let previousPresentation = presentationsByToken[token]
        guard previousPresentation != presentation else {
            return .unchanged
        }

        let conflictingOwner = presentationsByToken.contains { ownerToken, ownedPresentation in
            ownerToken != token &&
                ownedPresentation.id == presentation.id &&
                ownedPresentation != presentation
        }
        let conflictingActivePresentation = activeScenes.contains { activePresentation in
            activePresentation.id == presentation.id &&
                activePresentation != presentation &&
                activePresentation != previousPresentation
        }
        precondition(
            conflictingOwner == false && conflictingActivePresentation == false,
            "Scene lifecycle registrations require one presentation contract per scene UUID."
        )

        let presentationAlreadyOwned = presentationsByToken.contains { ownerToken, ownedPresentation in
            ownerToken != token && ownedPresentation == presentation
        }
        presentationsByToken[token] = presentation

        let presentationToDetach = previousPresentation.flatMap { previousPresentation in
            presentationsByToken.values.contains(previousPresentation) ? nil : previousPresentation
        }
        let presentationToAttach = presentationAlreadyOwned ? nil : presentation
        return SceneLifecycleChange(
            presentationToDetach: presentationToDetach,
            presentationToAttach: presentationToAttach
        )
    }

    internal mutating func unregister(_ token: UUID) -> ScenePresentation<R>? {
        guard let presentation = presentationsByToken.removeValue(forKey: token) else {
            return nil
        }

        return presentationsByToken.values.contains(presentation) ? nil : presentation
    }
}
