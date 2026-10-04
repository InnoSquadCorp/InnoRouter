// MARK: - RouterStateDraft.swift
// InnoRouterCore - mutable input for validated navigation state
// Copyright © 2026 Inno Squad. All rights reserved.

/// Mutable, value-semantic input for constructing a ``RouterState``.
///
/// A draft may temporarily contain invalid selections, identifiers, or
/// presentation options. ``build(resourceBudget:)`` checks structural resource
/// limits before recursively validating the complete tree. It throws a
/// ``RouterResourceLimitFailure`` or ``RouterStateValidationError`` rather than
/// exposing an invalid or over-budget state through this construction path.
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

    /// Uses the provisional finite budget before returning a complete state.
    /// Retained as an overload so existing no-argument method references remain
    /// valid as well as ordinary `build()` call sites.
    public func build() throws -> RouterState<R> {
        try build(resourceBudget: .provisional)
    }

    /// Validates every branch and scene under an explicitly selected budget.
    ///
    /// Failure leaves the draft unchanged so its input can be corrected and
    /// built again. Validation does not grant permission to execute a plan.
    /// Larger structural limits, or ``RouterResourceBudget/unlimited``, must be
    /// selected explicitly. Execution and retention fields are owned by Store
    /// and adapter admission, not by this value-construction operation.
    public func build(resourceBudget: RouterResourceBudget) throws -> RouterState<R> {
        try resourceBudget.validate(root: root, windows: windows, immersiveSpace: immersiveSpace)
        return try RouterState(
            root: root,
            windows: windows,
            immersiveSpace: immersiveSpace
        )
    }
}
