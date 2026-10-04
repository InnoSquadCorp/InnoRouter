// MARK: - RouterStateDraft.swift
// InnoRouterCore - mutable input for validated navigation state
// Copyright © 2026 Inno Squad. All rights reserved.

/// Mutable, value-semantic input for constructing a ``RouterState``.
///
/// A draft may temporarily contain invalid selections, identifiers, or
/// presentation options. ``build()`` validates the complete tree and throws a
/// ``RouterStateValidationError`` instead of exposing invalid router state.
/// Editing a draft does not change the state or another draft it was copied
/// from. A built value is still subject to execution policies and identity
/// continuity when applied as a ``RouterPlan``.
///
/// ```swift
/// var draft = RouterStateDraft(currentState)
/// draft.root = .stack(path: [.settings])
/// let plan = RouterPlan(state: try draft.build())
/// ```
public struct RouterStateDraft<R: Route>: Hashable, Sendable {
    public var root: RouterNode<R>
    public var windows: [RouterWindow<R>]
    public var immersiveSpace: RouterImmersiveSpace<R>?

    /// Creates mutable input without validating intermediate construction.
    public init(
        root: RouterNode<R> = .stack(),
        windows: [RouterWindow<R>] = [],
        immersiveSpace: RouterImmersiveSpace<R>? = nil
    ) {
        self.root = root
        self.windows = windows
        self.immersiveSpace = immersiveSpace
    }

    /// Copies a validated state into independently editable input.
    public init(_ state: RouterState<R>) {
        self.init(
            root: state.root,
            windows: state.windows,
            immersiveSpace: state.immersiveSpace
        )
    }

    /// Validates every branch and scene before returning a complete state.
    ///
    /// Failure leaves the draft unchanged so its input can be corrected and
    /// built again. Validation does not grant permission to execute a plan.
    public func build() throws -> RouterState<R> {
        try RouterState(
            root: root,
            windows: windows,
            immersiveSpace: immersiveSpace
        )
    }
}
