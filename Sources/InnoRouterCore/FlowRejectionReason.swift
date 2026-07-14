// MARK: - FlowRejectionReason.swift
// InnoRouterCore — rejection reasons surfaced by FlowStore when a
// user intent cannot be applied.
// Copyright © 2026 Inno Squad. All rights reserved.

/// Reason carried by `FlowEvent.intentRejected` when `FlowStore` refuses to
/// apply a user intent.
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

    /// A navigation or modal middleware cancelled the underlying command,
    /// so `FlowStore.path` was rolled back.
    case middlewareRejected(debugName: String?)
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
            return "Flow intent was rejected by middleware."
        }
    }
}
