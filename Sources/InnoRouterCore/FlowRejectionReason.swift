// MARK: - FlowRejectionReason.swift
// InnoRouterCore — rejection reasons surfaced by FlowStore when an
// intent or plan cannot be applied.
// Copyright © 2026 Inno Squad. All rights reserved.

/// Reason carried by `FlowEvent.intentRejected` or
/// ``FlowPlanApplyResult/rejected(currentPath:reason:)`` when `FlowStore`
/// refuses to apply a user intent or plan.
///
/// Lives in `InnoRouterCore` alongside the other rejection
/// taxonomies (``NavigationCancellationReason``,
/// ``ModalCancellationReason``, ``DeepLinkRejectionReason``) at the
/// same layer for symmetry. A future follow-up will promote
/// `FlowMutationPlan` and the execution journals to Core too; their
/// migration was deferred from PR #21 because it pulls the
/// middleware-registration chain transitively.
public enum FlowRejectionReason: Sendable, Equatable {
    /// A `.push` was requested while the flow tail is already a modal step.
    /// Dismiss the modal first, or use `.reset(_:)` to rewrite the stack.
    case pushBlockedByModalTail

    /// A `.reset(_:)` path violates FlowStore invariants (e.g. more than one
    /// modal step, or a modal step that is not the final element).
    case invalidResetPath

    /// A navigation or modal middleware cancelled the underlying command, or
    /// the navigation engine rejected it during atomic preview, so
    /// `FlowStore.path` was rolled back. A `nil` name can mean either an
    /// anonymous middleware cancellation or an engine-level refusal.
    case middlewareRejected(debugName: String?)

    /// `FlowStore.apply(_:)` was called synchronously while the store or one
    /// of its inner authorities was already delivering a mutation event.
    case reentrantApply
}

public extension FlowRejectionReason {
    var localizedDescription: String {
        switch self {
        case .pushBlockedByModalTail:
            return "Flow push was rejected because a modal is already at the tail."
        case .invalidResetPath:
            return "Flow reset path is invalid."
        case .middlewareRejected(let debugName):
            if let debugName {
                return "Flow intent was rejected by middleware '\(debugName)'."
            }
            return "Flow intent was rejected during navigation or middleware execution."
        case .reentrantApply:
            return "Flow plan application was rejected because reentrant apply is not supported."
        }
    }
}
