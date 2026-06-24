// MARK: - EventBroadcaster.swift
// InnoRouterCore — MainActor-isolated multi-subscriber event fan-out
// shared by every store authority.
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Package-internal helper that fans a single event out to multiple
/// `AsyncStream` subscribers.
///
/// Each store (`NavigationStore`, `ModalStore`, `FlowStore`,
/// `SceneStore`) owns one broadcaster keyed by its event enum.
/// Subscribers receive their own `AsyncStream` via `stream()`, and the
/// broadcaster cleans up per-subscriber state through
/// `AsyncStream.Continuation.onTermination` so cancelled `for await`
/// loops do not leak continuations. Termination callbacks are nonisolated, so
/// cleanup hops back to the main actor and `subscriberCount` is intentionally
/// an eventually-consistent test probe immediately after cancellation.
///
/// `@MainActor` isolation matches the authority of every store that
/// owns an instance. Continuation storage lives in a private helper so
/// stream teardown can finish outstanding continuations without forcing
/// the generic broadcaster deinitializer through Swift's actor-isolated
/// optimization path.
///
/// Lives in `InnoRouterCore` (not SwiftUI) because the fan-out is a
/// SwiftUI-free runtime primitive — `AsyncStream` + `UUID` +
/// `@MainActor` are all available without importing SwiftUI. Declared
/// at `package` visibility so every InnoRouter module can use the
/// same instance without paying a new public-API surface.
@MainActor
package final class EventBroadcaster<Event: Sendable> {
    private let continuationStorage = EventContinuationStorage<Event>()
    private let bufferingPolicy: EventBufferingPolicy

    package init(bufferingPolicy: EventBufferingPolicy = .default) {
        self.bufferingPolicy = bufferingPolicy
    }

    /// Returns a fresh `AsyncStream` that will receive every subsequent
    /// `broadcast(_:)` call until the consumer cancels its iterator or
    /// the broadcaster is deallocated.
    ///
    /// The subscriber's continuation uses the broadcaster's configured
    /// ``EventBufferingPolicy`` so a stalled consumer cannot retain events
    /// without bound.
    package func stream() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(
            bufferingPolicy: bufferingPolicy.asStreamPolicy()
        )
        continuationStorage.insert(continuation, for: id)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.continuationStorage.removeValue(forKey: id)
            }
        }
        return stream
    }

    /// Fans `event` out to every live subscriber. Continuations that
    /// have already terminated are ignored.
    package func broadcast(_ event: Event) {
        continuationStorage.broadcast(event)
    }

    /// Number of live subscribers — exposed for test observability.
    ///
    /// Cancellation cleanup is scheduled from `AsyncStream` termination back
    /// onto the main actor, so this value may include a just-terminated stream
    /// until that cleanup task drains.
    package var subscriberCount: Int {
        continuationStorage.count
    }
}

/// MainActor-confined storage accessed only through `EventBroadcaster`.
///
/// Keeping this helper nonisolated avoids Swift 6.3 optimizer crashes in the
/// generic actor-isolated broadcaster deinitializer while preserving a direct
/// continuation iteration path for broadcasts.
private final class EventContinuationStorage<Event: Sendable> {
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    var count: Int {
        continuations.count
    }

    func insert(_ continuation: AsyncStream<Event>.Continuation, for id: UUID) {
        continuations[id] = continuation
    }

    func removeValue(forKey id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func broadcast(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    deinit {
        let activeContinuations = Array(continuations.values)
        continuations.removeAll(keepingCapacity: false)

        for continuation in activeContinuations {
            continuation.finish()
        }
    }
}
