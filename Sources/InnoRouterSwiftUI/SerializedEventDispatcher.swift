// MARK: - SerializedEventDispatcher.swift
// InnoRouterSwiftUI - reentrancy-safe synchronous observation fan-out.
// Copyright © 2026 Inno Squad. All rights reserved.

/// Serializes synchronous store observation fan-out so reentrant observers
/// cannot interleave a later event ahead of the event currently being
/// delivered.
///
/// A store can enqueue a complete event sequence before delivery begins. If
/// an `onEvent` callback or another synchronous observer mutates the same
/// store, the resulting events are appended and delivered after the current
/// queued sequence has reached every observer.
@MainActor
final class SerializedEventDispatcher<Event> {
    private let deliver: @MainActor @Sendable (Event) -> Void
    private var pendingEvents: [Event] = []
    private var afterDeliveryActions: [@MainActor @Sendable () -> Void] = []
    private var nextEventIndex = 0
    private var nextActionIndex = 0
    private var isDelivering = false
    private var isDrainingActions = false
    private var executionBoundaryDepth = 0

    init(deliver: @escaping @MainActor @Sendable (Event) -> Void) {
        self.deliver = deliver
    }

    func emit(_ event: Event) {
        emit(contentsOf: [event])
    }

    func emit(contentsOf events: [Event]) {
        guard !events.isEmpty else { return }

        pendingEvents.append(contentsOf: events)
        guard !isDelivering else { return }

        isDelivering = true
        defer {
            pendingEvents.removeAll(keepingCapacity: true)
            nextEventIndex = 0
            isDelivering = false
            drainAfterDeliveryActionsIfPossible()
        }

        while nextEventIndex < pendingEvents.count {
            let event = pendingEvents[nextEventIndex]
            nextEventIndex += 1
            deliver(event)
        }
    }

    func performAfterDelivery(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        guard isDelivering || isDrainingActions || executionBoundaryDepth > 0 else {
            action()
            return
        }
        afterDeliveryActions.append(action)
    }

    func withExecutionBoundary<T>(_ body: () -> T) -> T {
        executionBoundaryDepth += 1
        defer {
            executionBoundaryDepth -= 1
            precondition(
                executionBoundaryDepth >= 0,
                "SerializedEventDispatcher execution boundary underflowed."
            )
            drainAfterDeliveryActionsIfPossible()
        }
        return body()
    }

    private func drainAfterDeliveryActionsIfPossible() {
        guard executionBoundaryDepth == 0, !isDelivering, !isDrainingActions else { return }
        guard nextActionIndex < afterDeliveryActions.count else { return }

        isDrainingActions = true
        defer {
            afterDeliveryActions.removeAll(keepingCapacity: true)
            nextActionIndex = 0
            isDrainingActions = false
        }

        while nextActionIndex < afterDeliveryActions.count {
            let action = afterDeliveryActions[nextActionIndex]
            nextActionIndex += 1
            action()
        }
    }
}
