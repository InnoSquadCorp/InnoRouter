import OSLog
import SwiftUI

import InnoRouterCore
import InnoRouterSwiftUI

typealias SceneOpenAction<R: Route> = @MainActor @Sendable (R) -> ScenePresentation<R>?
typealias SceneDismissWindowAction<R: Route> = @MainActor @Sendable (ScenePresentation<R>) -> Void
typealias SceneDismissImmersiveAction = @MainActor @Sendable () -> Void

/// Route-typed spatial scene capabilities published by a scene host or anchor.
///
/// This remains internal so the public surface only exposes
/// ``SceneRouterActions``. The optional open result lets generated scene
/// registries report a configuration invariant without fabricating a handle.
struct SceneRouterAuthority<R: Route>: Sendable {
    let open: SceneOpenAction<R>
    let dismissWindow: SceneDismissWindowAction<R>
    let dismissImmersive: SceneDismissImmersiveAction
}

@MainActor
private final class ErasedSceneRouterAuthority: Sendable {
    private let value: Any

    init<R: Route>(_ authority: SceneRouterAuthority<R>) {
        self.value = authority
    }

    func authority<R: Route>(for routeType: R.Type) -> SceneRouterAuthority<R>? {
        _ = routeType
        return value as? SceneRouterAuthority<R>
    }
}

/// Value-semantic environment payload for route-typed scene authorities.
/// Nested scene hosts can replace their own route type without mutating a
/// parent or sibling subtree.
struct SceneRouterEnvironment: Sendable {
    private var authorities: [ObjectIdentifier: ErasedSceneRouterAuthority] = [:]

    @MainActor
    subscript<R: Route>(routeType: R.Type) -> SceneRouterAuthority<R>? {
        get {
            authorities[ObjectIdentifier(routeType)]?.authority(for: routeType)
        }
        set {
            let key = ObjectIdentifier(routeType)
            if let newValue {
                authorities[key] = ErasedSceneRouterAuthority(newValue)
            } else {
                authorities.removeValue(forKey: key)
            }
        }
    }

    @MainActor
    mutating func register<R: Route>(
        _ authority: SceneRouterAuthority<R>,
        for routeType: R.Type
    ) {
        self[routeType] = authority
    }
}

extension EnvironmentValues {
    @Entry var sceneRouterEnvironment: SceneRouterEnvironment?
}

extension View {
    @MainActor
    func sceneRouterAuthority<R: Route>(
        _ authority: SceneRouterAuthority<R>,
        for routeType: R.Type
    ) -> some View {
        transformEnvironment(\.sceneRouterEnvironment) { environment in
            var resolved = environment ?? SceneRouterEnvironment()
            resolved.register(authority, for: routeType)
            environment = resolved
        }
    }
}

#if os(visionOS)
@MainActor
func makeSceneRouterAuthority<R: Route>(
    store: SceneStore<R>,
    scenes: SceneRegistry<R>
) -> SceneRouterAuthority<R> {
    SceneRouterAuthority(
        open: { route in
            guard let declaration = scenes.declaration(for: route) else {
                return nil
            }

            switch declaration.kind {
            case .window:
                return store.openWindow(route)
            case .volumetric(let size):
                return store.openVolumetric(route, size: size)
            case .immersive(let style):
                return store.openImmersive(route, style: style)
            }
        },
        dismissWindow: { presentation in
            store.dismissWindow(presentation)
        },
        dismissImmersive: {
            store.dismissImmersive()
        }
    )
}

extension View {
    /// Publishes the route-aware facade from the same store and registry used
    /// by `SceneHost` and `SceneAnchor`. Generated scene code only needs the
    /// existing public host/anchor modifiers; no implementation bridge leaks
    /// into the macro expansion.
    @MainActor
    func sceneRouterAuthority<R: Route>(
        store: SceneStore<R>,
        scenes: SceneRegistry<R>
    ) -> some View {
        sceneRouterAuthority(
            makeSceneRouterAuthority(store: store, scenes: scenes),
            for: R.self
        )
    }
}
#endif

/// Type-safe actions for opening and dismissing app-level scenes.
///
/// `open(_:)` reads the scene kind and metadata from the registry owned by the
/// nearest matching `innoRouterSceneHost` or `innoRouterSceneAnchor`, so callers
/// do not choose between window, volumetric, and immersive APIs themselves.
/// The returned value is a request handle; observe ``SceneStore/events`` for
/// the eventual presentation outcome.
///
/// The facade is available cross-platform so shared view code can compile,
/// while actual scene authority is currently published only on visionOS.
public struct SceneRouterActions<R: Route>: Sendable {
    private let resolveEnvironment: @MainActor @Sendable () -> SceneRouterEnvironment?
    private let environmentMissingPolicy: EnvironmentMissingPolicy
    private let routeType: R.Type

    @MainActor
    init(
        authority: SceneRouterAuthority<R>,
        environmentMissingPolicy: EnvironmentMissingPolicy = .crash
    ) {
        var environment = SceneRouterEnvironment()
        environment[R.self] = authority
        self.resolveEnvironment = { environment }
        self.environmentMissingPolicy = environmentMissingPolicy
        self.routeType = R.self
    }

    @MainActor
    init(
        routeType: R.Type,
        environmentMissingPolicy: EnvironmentMissingPolicy,
        resolveEnvironment: @escaping @MainActor @Sendable () -> SceneRouterEnvironment?
    ) {
        self.resolveEnvironment = resolveEnvironment
        self.environmentMissingPolicy = environmentMissingPolicy
        self.routeType = routeType
    }

    /// Requests the scene declared for `route`.
    ///
    /// The scene registry decides whether this opens a regular window, a
    /// volumetric window, or an immersive space. Returns `nil` only when the
    /// matching authority or declaration is unavailable and the configured
    /// ``EnvironmentMissingPolicy`` permits degradation.
    @MainActor
    @discardableResult
    public func open(_ route: R) -> ScenePresentation<R>? {
        guard let authority = authority(action: "open(_:)") else {
            return nil
        }
        guard let presentation = authority.open(route) else {
            reportMissing {
                "Scene declaration is missing in \(String(describing: routeType)) " +
                    "while invoking open(_:). " +
                    "Declare every scene route in the matching scene registry."
            }
            return nil
        }
        return presentation
    }

    /// Requests dismissal of a specific regular or volumetric window handle.
    ///
    /// Immersive spaces are intentionally dismissed through
    /// ``dismissImmersive()`` because SwiftUI dismisses the active immersive
    /// space rather than a presentation identity.
    @MainActor
    public func dismissWindow(_ presentation: ScenePresentation<R>) {
        guard let authority = authority(action: "dismissWindow(_:)") else {
            return
        }
        authority.dismissWindow(presentation)
    }

    /// Requests dismissal of the active immersive space.
    @MainActor
    public func dismissImmersive() {
        guard let authority = authority(action: "dismissImmersive()") else {
            return
        }
        authority.dismissImmersive()
    }

    @MainActor
    private func authority(action: String) -> SceneRouterAuthority<R>? {
        guard let environment = resolveEnvironment() else {
            reportMissing {
                "Scene router environment is missing for \(String(describing: routeType)) " +
                    "while invoking \(action). Install \(String(describing: routeType)).scenes " +
                    "in App.body and render this view from that generated scene tree. " +
                    "For manual composition, attach this view inside a matching " +
                    "innoRouterSceneHost or innoRouterSceneAnchor."
            }
            return nil
        }

        guard let authority = environment[routeType] else {
            reportMissing {
                "Scene router authority is missing for \(String(describing: routeType)) " +
                    "while invoking \(action). Ensure this view is rendered from " +
                    "\(String(describing: routeType)).scenes. For manual composition, " +
                    "ensure the nearest scene host or anchor uses the same route type."
            }
            return nil
        }

        return authority
    }

    @MainActor
    private func reportMissing(_ message: () -> String) {
        handleMissingSceneEnvironment(
            policy: environmentMissingPolicy,
            message: message
        )
    }
}

/// Reads route-aware scene actions from the nearest matching scene host or
/// anchor.
///
/// Resolution is lazy: rendering a view does not report missing wiring. The
/// current ``EnvironmentMissingPolicy`` is applied only when an action is
/// invoked without a matching authority.
///
/// ```swift
/// struct ControlsView: View {
///     @EnvironmentSceneRouter(AppScene.self) private var scenes
///
///     var body: some View {
///         Button("Open theatre") {
///             scenes.open(.theatre)
///         }
///     }
/// }
/// ```
@MainActor
@propertyWrapper
public struct EnvironmentSceneRouter<R: Route>: DynamicProperty {
    @Environment(\.sceneRouterEnvironment) private var sceneRouterEnvironment
    @Environment(\.innoRouterEnvironmentMissingPolicy) private var environmentMissingPolicy
    private let routeType: R.Type

    public init(_ routeType: R.Type) {
        self.routeType = routeType
    }

    public var wrappedValue: SceneRouterActions<R> {
        let environment = sceneRouterEnvironment
        return SceneRouterActions(
            routeType: routeType,
            environmentMissingPolicy: environmentMissingPolicy,
            resolveEnvironment: { environment }
        )
    }
}

@MainActor
private let missingSceneEnvironmentLogger = Logger(
    subsystem: "io.innosquad.innorouter",
    category: "scene-environment-missing"
)

@MainActor
private func handleMissingSceneEnvironment(
    policy: EnvironmentMissingPolicy,
    message: () -> String
) {
    switch policy {
    case .crash:
        preconditionFailure(message())
    case .logAndDegrade:
        let resolved = message()
        missingSceneEnvironmentLogger.error("\(resolved, privacy: .public)")
    case .assertAndLog:
        let resolved = message()
        missingSceneEnvironmentLogger.error("\(resolved, privacy: .public)")
        assertionFailure(resolved)
    }
}
