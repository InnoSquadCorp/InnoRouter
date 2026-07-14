// MARK: - ModalEvent.swift
// InnoRouterSwiftUI - unified observable event for ModalStore
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

/// A single event produced by a `ModalStore` observation surface.
///
/// These cases form the complete public `ModalStore` observation surface.
/// `ModalStore.events` exposes them as a single `AsyncStream<ModalEvent<M>>`
/// so callers can consume the same values delivered synchronously through
/// `ModalStoreConfiguration.onEvent`.
///
/// Test harnesses (`InnoRouterTesting`) reuse this type directly — the
/// legacy `ModalTestEvent<M>` is preserved as a typealias for source
/// compatibility.
public enum ModalEvent<M: Route>: Sendable, Equatable {
    /// A presentation became active.
    case presented(ModalPresentation<M>)

    /// The active presentation was dismissed.
    case dismissed(ModalPresentation<M>, reason: ModalDismissalReason)

    /// `ModalStore` replaced the active presentation in place.
    case replaced(old: ModalPresentation<M>, new: ModalPresentation<M>)

    /// The queued modal list changed.
    case queueChanged(old: [ModalPresentation<M>], new: [ModalPresentation<M>])

    /// One event per `execute(_:)` call, including cancelled and no-op
    /// outcomes.
    case commandIntercepted(command: ModalCommand<M>, result: ModalExecutionResult<M>)

    /// A middleware registry mutation succeeded.
    case middlewareMutation(ModalMiddlewareMutationEvent<M>)
}

extension ModalEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .presented(let presentation):
            return ".presented(\(presentation.route), style: \(presentation.style))"
        case .dismissed(let presentation, let reason):
            return ".dismissed(\(presentation.route), reason: \(reason))"
        case .replaced(let old, let new):
            return ".replaced(old: \(old.route), new: \(new.route))"
        case .queueChanged(let old, let new):
            return ".queueChanged(old.count: \(old.count), new.count: \(new.count))"
        case .commandIntercepted(let command, let result):
            return ".commandIntercepted(\(command), result: \(result))"
        case .middlewareMutation(let event):
            return ".middlewareMutation(action: \(event.action.rawValue))"
        }
    }
}
