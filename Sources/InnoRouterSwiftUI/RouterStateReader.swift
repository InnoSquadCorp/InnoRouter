// Read-only observation projection, independent of native rendering.
import InnoRouterCore

/// A read-only, observation-aware projection of the nearest router scope.
///
/// `RouterStateReader` intentionally exposes no mutation methods. Views can
/// read only the fields they render, while ``EnvironmentRouter`` remains the
/// macro-first action surface and ``RouterStore`` remains the only mutable
/// authority.
@MainActor
public struct RouterStateReader<R: Route>: Sendable {
    private let authority: (any RouterAuthorityProtocol<R>)?
    private let enclosingPresentation: RouterEnclosingPresentationEndpoint<R>?

    /// Creates a reader for an explicitly retained scope.
    public init(scope: RouterScope<R>) {
        self.authority = scope
        self.enclosingPresentation = nil
    }

    init(authority: some RouterAuthorityProtocol<R>, enclosingPresentation: RouterEnclosingPresentationEndpoint<R>? = nil) {
        self.authority = authority
        self.enclosingPresentation = enclosingPresentation
    }

    init() {
        self.authority = nil
        self.enclosingPresentation = nil
    }

    /// Whether a matching router authority is available in this view tree.
    public var isAvailable: Bool { authority != nil }

    /// Stable path of the projected subtree.
    public var scopePath: RouterScopePath? { authority?.path }

    /// The destination rendered at the root of a window or immersive scene.
    public var sceneRootRoute: R? { authority?.observedSceneRootRoute }

    /// The current node at ``scopePath``.
    public var node: RouterNode<R>? { authority?.node }

    /// The complete state owned by a direct scope's canonical store, or the
    /// feature-local state projected from a composed feature authority.
    ///
    /// Prefer the narrower node-derived properties below when a view does not
    /// need windows or immersive-space state, so sibling changes do not cause
    /// unnecessary invalidation. Feature projections intentionally omit the
    /// parent application's window and immersive-space inventory.
    public var state: RouterState<R>? { authority?.state }

    /// The path when the current node is a stack; otherwise an empty array.
    public var path: [R] {
        authority?.observedPath ?? []
    }

    /// The active presentation when the current node is a stack.
    public var presentation: RouterPresentation<R>? {
        authority?.observedPresentation
    }

    /// The exclusive navigation, alert, or confirmation-dialog family.
    public var presentationFamily: RouterPresentationFamily<R>? {
        authority?.observedPresentationFamily
    }

    /// Whether a scoped pop request can remove at least one route.
    public var canGoBack: Bool { !path.isEmpty }

    /// Whether this context can dismiss an owned or enclosing presentation.
    /// An explicit scope reader has no inherited enclosing context.
    public var canDismissPresentation: Bool { presentationFamily != nil || enclosingPresentation?.isCurrent == true }

    /// Selected branch when the current node is a container.
    public var selection: RouterScopeID? {
        authority?.observedSelection
    }

    /// Normalized positive badge counts for the current container.
    public var badges: [RouterScopeID: Int] {
        authority?.observedBadges ?? [:]
    }

    /// Native split layout metadata when the current node is a split container.
    public var split: RouterSplitState? { authority?.observedSplitState }

    /// Windows in the canonical whole-router state.
    public var windows: [RouterWindow<R>] { authority?.observedWindows ?? [] }

    /// Immersive space in the canonical whole-router state.
    public var immersiveSpace: RouterImmersiveSpace<R>? {
        authority?.observedImmersiveSpace
    }
}
