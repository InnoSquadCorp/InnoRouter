// MARK: - FlowEvent.swift
// InnoRouterSwiftUI - unified observable event for FlowStore
// Copyright © 2026 Inno Squad. All rights reserved.

import InnoRouterCore

/// A single event produced by a `FlowStore` observation surface.
///
/// `.pathChanged` and `.intentRejected` are the FlowStore-level cases delivered
/// through the unified `onEvent` callback and `events` stream.
/// `.navigation(...)` and `.modal(...)` wrap events from the inner
/// `NavigationStore` / `ModalStore`, so observers can assert
/// "this intent triggered this specific internal command sequence"
/// end-to-end from a single `AsyncStream`.
///
/// Test harnesses (`InnoRouterTesting`) reuse this type directly.
public enum FlowEvent<R: Route>: Sendable, Equatable {
    /// The projected flow path changed.
    case pathChanged(old: [RouteStep<R>], new: [RouteStep<R>])

    /// A flow intent was rejected.
    case intentRejected(FlowIntent<R>, FlowRejectionReason)

    /// The inner `NavigationStore` emitted an observation event.
    case navigation(NavigationEvent<R>)

    /// The inner `ModalStore` emitted an observation event.
    case modal(ModalEvent<R>)
}

extension FlowEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .pathChanged(let old, let new):
            return ".pathChanged(old: \(old), new: \(new))"
        case .intentRejected(let intent, let reason):
            return ".intentRejected(\(intent), reason: \(reason))"
        case .navigation(let event):
            return ".navigation(\(event))"
        case .modal(let event):
            return ".modal(\(event))"
        }
    }
}
