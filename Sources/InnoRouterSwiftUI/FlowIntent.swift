import InnoRouterCore

/// Public intent dispatched to `FlowStore.send(_:)`.
///
/// `FlowIntent` mirrors the intent layers used by `NavigationStore` /
/// `ModalStore` but operates on the unified `FlowStore` path where navigation
/// and modal progression live in a single array of `RouteStep`s.
///
/// Conformance to `Sendable` is **unconditional** because every ``Route`` is
/// required to be `Sendable`. Callers can therefore freely move `FlowIntent`
/// values across actor boundaries without additional `where R: Sendable`
/// constraints.
public enum FlowIntent<R: Route>: Sendable, Equatable {
    /// Push a route onto the navigation stack prefix of the flow.
    case push(R)
    /// Push multiple routes onto the navigation stack prefix as one
    /// coordinated flow mutation. An empty array is a silent no-op.
    case pushMany([R])
    /// Present a sheet modal as the tail of the flow.
    case presentSheet(R)
    /// Present a full-screen cover modal as the tail of the flow.
    case presentCover(R)
    /// Pop the last navigation push from the flow, if any.
    case pop
    /// Pop exactly `count` navigation pushes from the flow.
    ///
    /// Invalid counts leave the path unchanged, matching the result-discarding
    /// semantics of `NavigationStore.send(.backBy(count))`.
    case popCount(Int)
    /// Pop back to the last matching route in the navigation prefix.
    /// A missing route leaves the path unchanged.
    case popTo(R)
    /// Pop every navigation push and return to the host's root view.
    case popToRoot
    /// Dismiss the currently active modal tail, if any.
    case dismiss
    /// Dismiss the active modal tail and clear every queued presentation.
    case dismissAll
    /// Replace the flow path with the supplied steps, subject to the
    /// FlowStore invariants (at most one modal step, and only at the tail).
    case reset([RouteStep<R>])

    /// Replace the navigation push prefix with `routes` and **drop any
    /// active modal tail**.
    ///
    /// Mirrors `NavigationIntent.replaceStack([R])` on the flow surface.
    /// Because the flow's modal invariant forbids modal steps in any
    /// non-tail position, a "replace stack" operation can't preserve
    /// a modal by definition — any active modal is dismissed as part
    /// of the reset.
    ///
    /// Equivalent to `.reset(routes.map(RouteStep.push))` but
    /// communicates intent at the call site.
    case replaceStack([R])

    /// If `route` already exists in the current navigation push
    /// prefix, pop back to it. Otherwise, behave like `.push(route)`.
    ///
    /// Mirrors `NavigationIntent.backOrPush(R)`. When a modal tail is
    /// active, the intent is rejected with
    /// `.pushBlockedByModalTail` whether `route` already exists or
    /// would need to be pushed.
    case backOrPush(R)

    /// If the current navigation stack already contains `route`
    /// anywhere, this intent is a silent no-op. Otherwise it behaves
    /// like `.push(route)`.
    ///
    /// Mirrors `NavigationIntent.pushUniqueRoot(R)`. When a modal tail
    /// is active and the intent would otherwise push, it's rejected
    /// with `.pushBlockedByModalTail`, matching `.push` semantics.
    case pushUniqueRoot(R)

    /// Dismiss any active modal tail, then behave like
    /// ``backOrPush(_:)``. Equivalent to sending `.dismiss` followed
    /// by `.backOrPush(route)` but as a single intent so
    /// middleware / telemetry observes a coherent signal.
    ///
    /// If the modal dismiss is cancelled by middleware, the outer
    /// intent surfaces the rejection and the inner operation does
    /// **not** run. If dismissing the active modal promotes a queued
    /// modal instead, the outer intent is rejected with
    /// `.pushBlockedByModalTail` and the inner operation still does
    /// not run.
    case backOrPushDismissingModal(R)

    /// Dismiss any active modal tail, then behave like
    /// ``pushUniqueRoot(_:)``. Same cancellation propagation rules
    /// as ``backOrPushDismissingModal(_:)``.
    case pushUniqueRootDismissingModal(R)
}

// `FlowRejectionReason` lives in `InnoRouterCore` so it sits next to
// the other rejection taxonomies (`NavigationCancellationReason`,
// `ModalCancellationReason`, `DeepLinkRejectionReason`).
// See `Sources/InnoRouterCore/FlowRejectionReason.swift`.
