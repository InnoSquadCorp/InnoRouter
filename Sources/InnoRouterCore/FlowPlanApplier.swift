// MARK: - FlowPlanApplier.swift
// InnoRouterCore - cross-module bridge for applying FlowPlan values
// Copyright © 2026 Inno Squad. All rights reserved.

/// Outcome of applying a ``FlowPlan`` to a concrete authority.
public enum FlowPlanApplyResult<R: Route>: Sendable, Equatable {
    /// The plan was committed and the authority now reflects `path`.
    case applied(path: [RouteStep<R>])
    /// The plan was rejected for `reason`. `currentPath` is the authority's
    /// path snapshot at the point of rejection.
    case rejected(currentPath: [RouteStep<R>], reason: FlowRejectionReason)
}

/// A MainActor-isolated authority that can apply a ``FlowPlan`` as a
/// single coordinated operation.
///
/// This protocol exists so higher-level modules (deep-link effect
/// handlers, URL routers, state restoration drivers) can depend on
/// InnoRouterCore without pulling in the SwiftUI-layer `FlowStore`
/// type directly. `FlowStore` in `InnoRouterSwiftUI` already ships
/// `apply(_ plan:)` and conforms to this protocol in an extension.
///
/// Conforming types are expected to honour the `FlowStore`
/// invariants that a `FlowPlan` already respects: at most one modal
/// step, and a modal step only at the tail of the path. The protocol models
/// FlowStore-compatible authorities; conformers map every refusal to the
/// corresponding ``FlowRejectionReason`` rather than introducing an untyped
/// failure channel.
@MainActor
public protocol FlowPlanApplier<RouteType>: AnyObject, Sendable {
    associatedtype RouteType: Route

    /// Applies `plan` to the underlying authority. The call is
    /// expected to complete synchronously on the main actor so the
    /// caller can observe the resulting state immediately. Authorities may
    /// reject a reentrant application made from one of their synchronous
    /// observation callbacks when deferring it would make this result
    /// misleading.
    func apply(_ plan: FlowPlan<RouteType>) -> FlowPlanApplyResult<RouteType>
}
