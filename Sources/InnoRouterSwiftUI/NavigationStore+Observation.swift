import InnoRouterCore

// MARK: - Observation delivery

extension NavigationStore {
    func performAfterObservationDelivery(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        eventDispatcher.performAfterDelivery(action)
    }

    func emitObservationEvent(_ event: NavigationEvent<R>) {
        eventDispatcher.emit(
            NavigationObservationDelivery(
                event: event,
                telemetryEvent: nil
            )
        )
    }
}
