import SwiftUI

import InnoRouterCore

public extension RouterActions where R: RouterSceneRoute {
    /// Opens one macro-generated regular-window destination.
    @MainActor @discardableResult
    func openWindow(
        _ request: RouterWindowRequest<R>,
        id: UUID = UUID()
    ) -> Task<RouterOutcome<R>, Never> {
        guard let scene = R.routerScene(for: request.route),
              scene.style == .window,
              scene.id == request.sceneID else {
            return sceneRejectionTask(style: .window)
        }
        return openWindow(request.route, id: id)
    }

    @MainActor @discardableResult
    func openWindow(_ route: R, id: UUID = UUID()) -> Task<RouterOutcome<R>, Never> {
        guard let scene = R.routerScene(for: route), scene.style == .window else {
            return sceneRejectionTask(style: .window)
        }
#if os(tvOS) || os(watchOS)
        return sceneRejectionTask(style: .window)
#else
        return rootDispatch(
            .openWindow(.init(id: id, route: route)),
            action: "openWindow(_:id:)"
        )
#endif
    }

    @MainActor @discardableResult
    func dismissWindow(_ id: UUID) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.dismissWindow(id), action: "dismissWindow(_:)")
    }

    @MainActor @discardableResult
    func enterImmersiveSpace(
        id: String,
        route: R
    ) -> Task<RouterOutcome<R>, Never> {
        guard let scene = R.routerScene(for: route), scene.style == .immersiveSpace else {
            return sceneRejectionTask(style: .immersiveSpace)
        }
        guard scene.id == id else {
            return sceneRejectionTask(
                reason: .sceneIdentifierMismatch(expected: scene.id, actual: id)
            )
        }
#if os(visionOS)
        return rootDispatch(
            .enterImmersiveSpace(.init(id: id, route: route)),
            action: "enterImmersiveSpace(id:route:)"
        )
#else
        return sceneRejectionTask(style: .immersiveSpace)
#endif
    }

    /// Opens one macro-generated immersive destination without duplicating its
    /// application-owned scene identifier at the call site.
    @MainActor @discardableResult
    func enterImmersiveSpace(
        _ request: RouterImmersiveSpaceRequest<R>
    ) -> Task<RouterOutcome<R>, Never> {
        enterImmersiveSpace(id: request.sceneID, route: request.route)
    }

    @MainActor @discardableResult
    func dismissImmersiveSpace() -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.dismissImmersiveSpace, action: "dismissImmersiveSpace()")
    }

    @MainActor
    private func sceneRejectionTask(
        style: RouterSceneStyle
    ) -> Task<RouterOutcome<R>, Never> {
        sceneRejectionTask(
            reason: .unsupportedScene(
                routeType: String(describing: R.self),
                style: style.rawValue
            )
        )
    }

    @MainActor
    private func sceneRejectionTask(
        reason: RouterMutationError
    ) -> Task<RouterOutcome<R>, Never> {
        guard let authority = routerAuthority(action: "scene action") else {
            return missingAuthorityTask()
        }
        let outcome = authority.reject(.mutation(reason))
        return Task { outcome }
    }
}

public extension RouterActions where R: RouterTabRoute {
    @MainActor @discardableResult
    func select(_ tab: R.Tab) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.select(tab.routerScopeID), action: "select(_:)")
    }

    @MainActor @discardableResult
    func setBadge(_ count: Int, for tab: R.Tab) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.setBadge(count, for: tab.routerScopeID), action: "setBadge(_:for:)")
    }

    @MainActor @discardableResult
    func clearBadge(for tab: R.Tab) -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.setBadge(nil, for: tab.routerScopeID), action: "clearBadge(for:)")
    }

    @MainActor @discardableResult
    func clearAllBadges() -> Task<RouterOutcome<R>, Never> {
        rootDispatch(.clearAllBadges, action: "clearAllBadges()")
    }
}
