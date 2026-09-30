// MARK: - EventBufferingPolicy.swift
// InnoRouterCore — backpressure knob for store event broadcasters
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Backpressure policy applied to each `RouterStore` event subscriber's
/// `AsyncStream` continuation.
///
/// Stores fan a single observation event out to every subscriber. A slow or
/// cancelled subscriber can retain an arbitrary number of events if no policy
/// caps the queue, which behaves as an unbounded leak when the broadcaster
/// outlives all consumers. The default policy is ``bufferingNewest(_:)`` with
/// a 1024-event ceiling — large enough to cover realistic navigation bursts
/// while keeping the retained working set bounded. Callers that genuinely
/// need every event (for example, deterministic test harnesses) can opt in to
/// ``unbounded``.
public enum EventBufferingPolicy: Sendable, Equatable {
    /// Buffer every event until the subscriber drains it.
    ///
    /// Matches the pre-3.0 behaviour: no bound, full ordering. Use this for
    /// test harnesses or short-lived subscribers where you control lifetime.
    case unbounded
    /// Retain at most `limit` most-recently-broadcast events per subscriber,
    /// dropping older events when the buffer fills.
    case bufferingNewest(Int)
    /// Retain at most `limit` oldest-broadcast events per subscriber,
    /// dropping newer events when the buffer fills.
    case bufferingOldest(Int)

    /// Maps to the underlying `AsyncStream.Continuation.BufferingPolicy` for
    /// the requested element type. Package-internal so the shape of the
    /// broadcaster plumbing stays a hidden detail of `EventBroadcaster`.
    package func asStreamPolicy<Element>(
        _ elementType: Element.Type = Element.self
    ) -> AsyncStream<Element>.Continuation.BufferingPolicy {
        switch self {
        case .unbounded:
            return .unbounded
        case .bufferingNewest(let limit):
            return .bufferingNewest(limit)
        case .bufferingOldest(let limit):
            return .bufferingOldest(limit)
        }
    }
}

public extension EventBufferingPolicy {
    /// The store default applied when callers don't override via
    /// ``RouterStoreConfiguration/eventBufferingPolicy``: buffer the most
    /// recent 1024 events per subscriber.
    static let `default`: EventBufferingPolicy = .bufferingNewest(1024)
}
