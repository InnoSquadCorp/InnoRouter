// MARK: - RouterAction.swift
// InnoRouterCore - canonical requests, plans, and mutation failures
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Invalid structural state rejected before it can become router authority.
public enum RouterStateValidationError: Error, Hashable, Sendable {
    case emptyScope
    case emptyContainer(style: RouterContainerStyle)
    case duplicateScope
    case missingSelection(RouterScopeID)
    case selectionRequired(style: RouterContainerStyle)
    case unknownBadgeScope(RouterScopeID)
    case invalidBadgeCount(scope: RouterScopeID, count: Int)
    case duplicatePresentation(UUID)
    case invalidPresentationDetent(RouterPresentationDetent)
    case undeclaredSelectedDetent(RouterPresentationDetent)
    case undeclaredBackgroundInteractionDetent(RouterPresentationDetent)
    case invalidPresentationCornerRadius(Double)
    case duplicateWindow
    case emptyImmersiveSpaceID
    case missingSplitState
    case unexpectedSplitState
    case duplicateSplitColumnScope
    case missingSplitColumn(RouterSplitColumn)
    case unexpectedSplitColumnScope(RouterScopeID)
    case unavailableSplitColumn(RouterSplitColumn)
}

/// An exact target state used by deep links, restoration, and transactions.
public struct RouterPlan<R: Route>: Hashable, Sendable {
    public var state: RouterState<R>

    public init(state: RouterState<R>) {
        self.state = state
    }
}

extension RouterPlan: Codable where R: Codable {}

/// The one incremental request vocabulary accepted by ``RouterStore``.
public indirect enum RouterAction<R: Route>: Hashable, Sendable {
    case push(R)
    case pushIfNeeded(R)
    case backOrPush(R)
    case replaceTop(R)
    case pushMany([R])
    case pop(count: Int)
    case popTo(R)
    case popToRoot
    case replaceStack([R])
    case present(RouterPresentation<R>)
    case dismissPresentation
    case setPresentationDetent(RouterPresentationDetent)
    case select(RouterScopeID)
    case setBadge(Int?, for: RouterScopeID)
    case clearAllBadges
    case setSplitVisibility(RouterSplitVisibility)
    case setPreferredCompactColumn(RouterSplitColumn)
    case scoped(RouterScopeID, RouterAction<R>)
    case windowScoped(UUID, RouterAction<R>)
    case immersiveSpaceScoped(String, RouterAction<R>)
    case openWindow(RouterWindow<R>)
    case dismissWindow(UUID)
    case enterImmersiveSpace(RouterImmersiveSpace<R>)
    case dismissImmersiveSpace
    case apply(RouterPlan<R>)

    /// Targets this action at one child scope.
    public func inScope(_ scope: RouterScopeID) -> RouterAction<R> {
        .scoped(scope, self)
    }

    /// Targets this action at a complete nested scope path.
    public func inScope(_ path: RouterScopePath) -> RouterAction<R> {
        let nested = path.components.reversed().reduce(self) { action, scope in
            .scoped(scope, action)
        }
        switch path.domain {
        case .application:
            return nested
        case .window(let id):
            return .windowScoped(id, nested)
        case .immersiveSpace(let id):
            return .immersiveSpaceScoped(id, nested)
        }
    }
}

extension RouterAction: Codable where R: Codable {}

/// A precise reason why an action cannot produce a valid next state.
public enum RouterMutationError: Error, Hashable, Sendable {
    case expectedStack(RouterScopePath)
    case expectedContainer(RouterScopePath)
    case expectedSplitContainer(RouterScopePath)
    case unavailableSplitColumn(RouterSplitColumn, scope: RouterScopePath)
    case missingScope(RouterScopeID, parent: RouterScopePath)
    case invalidPopCount(requested: Int, available: Int, scope: RouterScopePath)
    case blockedByPresentation(RouterScopePath)
    case presentationAlreadyActive(RouterScopePath)
    case presentationNotActive(RouterScopePath)
    case presentationIdentityMismatch(
        scope: RouterScopePath,
        expected: UUID,
        actual: UUID?
    )
    case unavailablePresentationDetent(RouterPresentationDetent, scope: RouterScopePath)
    case presentationIdentityConflict(UUID)
    case windowIdentityConflict(UUID)
    case unsupportedScene(routeType: String, style: String)
    case sceneIdentifierMismatch(expected: String, actual: String)
    case windowNotFound(UUID)
    case immersiveSpaceNotFound(String)
    case scopedGlobalAction(RouterScopePath)
    case invalidTargetState(RouterStateValidationError)
    case incompatibleNavigationTopology(RouterScopePath)
}
