// MARK: - SceneInventory.swift
// InnoRouterSpatial — active spatial scene inventory and recency projection.

import Foundation

import InnoRouterCore

internal struct SceneStoreSnapshot<R: Route>: Equatable {
    internal let currentScene: ScenePresentation<R>?
    internal let activeScenes: [ScenePresentation<R>]
    internal let openWindowsByID: [UUID: ScenePresentation<R>]
    internal let activeImmersive: ScenePresentation<R>?

    internal var hasActiveScenes: Bool {
        !activeScenes.isEmpty
    }

    internal func windowPresentation(id: UUID) -> ScenePresentation<R>? {
        openWindowsByID[id]
    }

    internal func windowPresentations(for route: R) -> [ScenePresentation<R>] {
        activeScenes.filter { $0.route == route && $0.isWindowLike }
    }
}

internal struct SceneInventory<R: Route>: Equatable {
    private var openWindowsByID: [UUID: ScenePresentation<R>] = [:]
    internal private(set) var activeImmersive: ScenePresentation<R>?
    private var activeScenesInRecencyOrder: [ScenePresentation<R>] = []

    internal var currentScene: ScenePresentation<R>? {
        activeScenes.last
    }

    internal var activeScenes: [ScenePresentation<R>] {
        activeScenesInRecencyOrder.filter(isActive)
    }

    internal var snapshot: SceneStoreSnapshot<R> {
        SceneStoreSnapshot(
            currentScene: currentScene,
            activeScenes: activeScenes,
            openWindowsByID: openWindowsByID,
            activeImmersive: activeImmersive
        )
    }

    internal func contains(_ presentation: ScenePresentation<R>) -> Bool {
        switch presentation {
        case .window, .volumetric:
            return openWindowsByID[presentation.id] == presentation
        case .immersive:
            return activeImmersive == presentation
        }
    }

    internal func hasWindow(id: UUID) -> Bool {
        openWindowsByID[id] != nil
    }

    internal mutating func activate(_ presentation: ScenePresentation<R>) {
        switch presentation {
        case .window, .volumetric:
            openWindowsByID[presentation.id] = presentation
        case .immersive:
            if let activeImmersive, activeImmersive.id != presentation.id {
                activeScenesInRecencyOrder.removeAll { $0.id == activeImmersive.id }
            }
            self.activeImmersive = presentation
        }

        touch(presentation)
        removeInactiveRecencyEntries()
    }

    internal mutating func deactivate(_ presentation: ScenePresentation<R>) {
        let didDeactivate: Bool
        switch presentation {
        case .window, .volumetric:
            if openWindowsByID[presentation.id] == presentation {
                openWindowsByID.removeValue(forKey: presentation.id)
                didDeactivate = true
            } else {
                didDeactivate = false
            }
        case .immersive:
            if activeImmersive == presentation {
                activeImmersive = nil
                didDeactivate = true
            } else {
                didDeactivate = false
            }
        }

        guard didDeactivate else { return }
        activeScenesInRecencyOrder.removeAll { $0.id == presentation.id }
        removeInactiveRecencyEntries()
    }

    internal mutating func clearImmersive() {
        activeImmersive = nil
        activeScenesInRecencyOrder.removeAll { $0.isImmersive }
        removeInactiveRecencyEntries()
    }

    private mutating func touch(_ presentation: ScenePresentation<R>) {
        activeScenesInRecencyOrder.removeAll { $0.id == presentation.id }
        activeScenesInRecencyOrder.append(presentation)
    }

    private mutating func removeInactiveRecencyEntries() {
        activeScenesInRecencyOrder = activeScenes
    }

    private func isActive(_ presentation: ScenePresentation<R>) -> Bool {
        switch presentation {
        case .window, .volumetric:
            return openWindowsByID[presentation.id] == presentation
        case .immersive:
            return activeImmersive == presentation
        }
    }
}
