// MARK: - SceneContracts.swift
// InnoRouterSpatial — public contract types for the spatial scene
// surface (events, intents, declarations, registry).

import Foundation

import InnoRouterCore

/// Lifecycle event emitted by ``SceneStore``.
///
/// Subscribers reach these through ``SceneStore/events``. The event
/// taxonomy is intentionally minimal — InnoRouter only observes outcomes
/// the SwiftUI environment actually reports, and leaves deeper
/// instrumentation to app telemetry.
public enum SceneEvent<R: Route>: Sendable, Equatable {
    /// A scene was successfully presented.
    case presented(ScenePresentation<R>)

    /// A scene was dismissed.
    case dismissed(ScenePresentation<R>)

    /// An open or dismiss request was rejected.
    case rejected(SceneIntent<R>, reason: SceneRejectionReason)

    /// An `innoRouterSceneHost` modifier tried to register but the store
    /// already has a primary dispatcher. The losing host goes dormant
    /// instead of crashing so SwiftUI scene rehydration and hot-reload
    /// don't take the app down.
    case hostRegistrationRejected(reason: SceneRejectionReason)
}

/// Reason a ``SceneStore`` open/dismiss intent was rejected.
public enum SceneRejectionReason: String, Sendable, Equatable, Codable {
    /// The SwiftUI environment returned a non-success result (for example
    /// `OpenImmersiveSpaceAction.Result.userCancelled` or `.error`).
    case environmentReturnedFailure

    /// The store was asked to dismiss when nothing was active.
    case nothingActive

    /// The active scene does not match the requested dismissal.
    case activeSceneMismatch

    /// The requested route is missing from the host's scene registry.
    case sceneNotDeclared

    /// The requested presentation does not match the declared scene kind
    /// or metadata in the host's scene registry.
    case sceneDeclarationMismatch

    /// The requested scene instance is not currently active in the
    /// store's inventory.
    case sceneInstanceNotActive

    /// A newer intent replaced the pending intent before the host could
    /// commit it.
    case supersededByNewerIntent

    /// The currently elected dispatcher is a fallback scene-anchor modifier
    /// attached to a different scene than the one the intent would
    /// affect, so the intent is refused instead of being serviced from
    /// an unrelated scene. Apps typically see this after the preferred
    /// primary host scene disappears while cross-scene opens are still
    /// queued; attach a new `innoRouterSceneHost` modifier to resume delivery.
    case fallbackCannotDispatch

    /// A second `innoRouterSceneHost` modifier tried to register with the
    /// store while another host was already primary. The losing host goes dormant
    /// rather than crashing so SwiftUI scene rehydration and hot-reload
    /// sequences remain safe in production. Apps that hit this reason
    /// in normal steady state should attach exactly one
    /// `innoRouterSceneHost` modifier per ``SceneStore``.
    case duplicateHostRegistration

    /// The dispatcher's ``Task`` was cancelled (the owning view
    /// disappeared, or the signal re-entered with a fresh dispatch
    /// attempt) while a claimed intent was mid-flight. The claim is
    /// released and the pending intent advances instead of leaving the
    /// queue stuck behind an orphaned claim.
    case hostTornDownDuringDispatch

    public var localizedDescription: String {
        switch self {
        case .environmentReturnedFailure:
            return "Scene environment returned a failure."
        case .nothingActive:
            return "No scene is currently active."
        case .activeSceneMismatch:
            return "The active scene does not match the dismissal request."
        case .sceneNotDeclared:
            return "The requested scene is not declared."
        case .sceneDeclarationMismatch:
            return "The requested scene does not match its declaration."
        case .sceneInstanceNotActive:
            return "The requested scene instance is not active."
        case .supersededByNewerIntent:
            return "Scene intent was superseded by a newer intent."
        case .fallbackCannotDispatch:
            return "Fallback scene dispatcher cannot service this intent."
        case .duplicateHostRegistration:
            return "A duplicate scene host registration was rejected."
        case .hostTornDownDuringDispatch:
            return "Scene host was torn down during dispatch."
        }
    }
}

/// Capability advertised by a dispatcher (``SceneHost`` or
/// ``SceneAnchor``) when it runs the dispatch loop.
///
/// Primary hosts can service any intent. Fallback anchors are
/// deliberately restricted to operations that do not require
/// authority over other scenes: dismissals of any scene and opens
/// that target the anchor's own attached scene. Other opens are
/// rejected with ``SceneRejectionReason/fallbackCannotDispatch`` so
/// the queue advances instead of being silently committed by a
/// dispatcher that cannot actually reach the target scene.
internal enum SceneDispatchCapability<R: Route>: Equatable {
    /// Full dispatch authority, held by exactly one ``SceneHost`` per
    /// store.
    case primaryHost

    /// Restricted dispatch authority, held by any ``SceneAnchor``.
    /// Opens for the same scene declaration (including another value-based
    /// window instance) and any dismissal are serviceable; cross-scene opens
    /// are refused.
    case fallbackAnchor(attachedTo: ScenePresentation<R>)
}

/// Intent queued by ``SceneStore`` for the host modifier to act on.
///
/// The store doesn't call SwiftUI's `openWindow` / `openImmersiveSpace`
/// actions directly — those are only accessible from a view's
/// environment. Instead the store publishes an intent here and a
/// `innoRouterSceneHost` observes it and dispatches.
public enum SceneIntent<R: Route>: Sendable, Equatable {
    /// Open the given spatial presentation.
    case open(ScenePresentation<R>)

    /// Dismiss the currently active immersive space.
    case dismissImmersive

    /// Dismiss the specific window instance identified by `presentation`.
    case dismissWindow(ScenePresentation<R>)
}

/// Declared scene metadata shared between your `App` scene declarations
/// and the scene host/anchor modifiers.
public struct SceneDeclaration<R: Route>: Sendable, Hashable {
    /// The kind of scene declared for a route.
    internal enum Kind: Sendable, Hashable {
        /// A regular window.
        case window

        /// A volumetric window with the declared size contract.
        case volumetric(size: VolumetricSize? = nil)

        /// An immersive space with the declared immersion style.
        case immersive(style: ImmersiveStyle)
    }

    /// Route represented by this declaration.
    internal let route: R

    /// SwiftUI scene identifier used by `WindowGroup(id:for:)` or
    /// `ImmersiveSpace(id:)`.
    internal let id: String

    /// Declared kind and metadata contract for the route.
    internal let kind: Kind

    /// Creates a scene declaration.
    private init(route: R, id: String, kind: Kind) {
        self.route = route
        self.id = id
        self.kind = kind
    }

    /// Declares a regular window for `route`.
    public static func window(_ route: R, id: String) -> Self {
        .init(route: route, id: id, kind: .window)
    }

    /// Declares a volumetric window for `route`.
    public static func volumetric(_ route: R, id: String, size: VolumetricSize? = nil) -> Self {
        .init(route: route, id: id, kind: .volumetric(size: size))
    }

    /// Declares an immersive space for `route`.
    public static func immersive(_ route: R, id: String, style: ImmersiveStyle) -> Self {
        .init(route: route, id: id, kind: .immersive(style: style))
    }
}

/// Registry of scenes that the spatial host and anchor modifiers can dispatch.
///
/// Build the registry from stable scene identifier constants, use those same
/// constants in your `App`'s `WindowGroup` / `ImmersiveSpace` declarations,
/// and pass the opaque registry to the host and anchor modifiers.
public struct SceneRegistry<R: Route>: Sendable {
    private let declarationsByRoute: [R: SceneDeclaration<R>]

    /// Creates a registry from an array of scene declarations.
    public init(_ declarations: [SceneDeclaration<R>]) {
        var declarationsByRoute: [R: SceneDeclaration<R>] = [:]
        var declarationIDs: Set<String> = []

        for declaration in declarations {
            let duplicateRoute = declarationsByRoute.updateValue(declaration, forKey: declaration.route)
            precondition(
                duplicateRoute == nil,
                "SceneRegistry requires unique routes. Duplicate route: \(String(describing: declaration.route))"
            )

            let insertedID = declarationIDs.insert(declaration.id).inserted
            precondition(
                insertedID,
                "SceneRegistry requires unique ids. Duplicate id: \(declaration.id)"
            )
        }

        self.declarationsByRoute = declarationsByRoute
    }

    /// Creates a registry from a variadic list of scene declarations.
    public init(_ declarations: SceneDeclaration<R>...) {
        self.init(declarations)
    }

    /// Returns the declaration registered for `route`, if any.
    internal func declaration(for route: R) -> SceneDeclaration<R>? {
        declarationsByRoute[route]
    }
}

internal extension ScenePresentation {
    var route: R {
        switch self {
        case .window(let route, _), .volumetric(let route, _, _), .immersive(let route, _, _):
            return route
        }
    }

    var id: UUID {
        switch self {
        case .window(_, let id), .volumetric(_, _, let id), .immersive(_, _, let id):
            return id
        }
    }

    var isImmersive: Bool {
        if case .immersive = self {
            return true
        }
        return false
    }

    var isWindowLike: Bool {
        !isImmersive
    }

    func matchesWindowDismissal(of presentation: ScenePresentation<R>) -> Bool {
        isWindowLike && presentation.isWindowLike && id == presentation.id
    }
}

internal extension SceneIntent {
    var openedPresentation: ScenePresentation<R>? {
        if case .open(let presentation) = self {
            return presentation
        }
        return nil
    }

    var isImmersiveOperation: Bool {
        switch self {
        case .open(let presentation):
            return presentation.isImmersive
        case .dismissImmersive:
            return true
        case .dismissWindow:
            return false
        }
    }

    func dismissesSameScene(as presentation: ScenePresentation<R>) -> Bool {
        switch self {
        case .open:
            return false
        case .dismissImmersive:
            return presentation.isImmersive
        case .dismissWindow(let requestedPresentation):
            return presentation.matchesWindowDismissal(of: requestedPresentation)
        }
    }
}

internal extension SceneDeclaration {
    func presentation(id: UUID = UUID()) -> ScenePresentation<R> {
        switch kind {
        case .window:
            return .window(route, id: id)
        case .volumetric(let size):
            return .volumetric(route, size: size, id: id)
        case .immersive(let style):
            return .immersive(route, style: style, id: id)
        }
    }

    func matches(_ presentation: ScenePresentation<R>) -> Bool {
        guard route == presentation.route else {
            return false
        }

        switch (kind, presentation) {
        case (.window, .window):
            return true
        case (.volumetric(let declaredSize), .volumetric(_, let actualSize, _)):
            return declaredSize == actualSize
        case (.immersive(let declaredStyle), .immersive(_, let actualStyle, _)):
            return declaredStyle == actualStyle
        default:
            return false
        }
    }
}
