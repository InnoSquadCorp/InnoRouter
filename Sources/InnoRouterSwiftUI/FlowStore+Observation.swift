import InnoRouterCore

@MainActor
extension FlowStore {
    internal func handleNavigationStoreEvent(_ event: NavigationEvent<R>) {
        if reentrancy.isApplyingInternalMutation {
            precondition(
                reentrancy.isBuffering,
                "FlowStore navigation event escaped its mutation buffer."
            )
        }
        guard case .changed = event else {
            emitFlowEvent(.navigation(event))
            return
        }

        let oldPath = path
        syncPathFromStoresWithoutEmitting()

        var events: [FlowEvent<R>] = [.navigation(event)]
        if !reentrancy.isBuffering, oldPath != path {
            events.append(.pathChanged(old: oldPath, new: path))
        }
        emitFlowEvents(events)
    }

    internal func handleModalStoreEvent(_ event: ModalEvent<R>) {
        if reentrancy.isApplyingInternalMutation {
            precondition(
                reentrancy.isBuffering,
                "FlowStore modal event escaped its mutation buffer."
            )
        }
        if reentrancy.isBuffering {
            syncPathFromStoresWithoutEmitting()
            emitFlowEvent(.modal(event))
            return
        }

        switch event {
        case .middlewareMutation:
            emitFlowEvent(.modal(event))

        case .presented, .dismissed, .replaced, .queueChanged:
            if pendingDirectModalOldPath == nil {
                pendingDirectModalOldPath = path
            }
            syncPathFromStoresWithoutEmitting()
            pendingDirectModalEvents.append(.modal(event))

        case .commandIntercepted:
            let oldPath = pendingDirectModalOldPath ?? path
            if pendingDirectModalOldPath == nil {
                pendingDirectModalOldPath = oldPath
            }
            syncPathFromStoresWithoutEmitting()
            pendingDirectModalEvents.append(.modal(event))

            var events = pendingDirectModalEvents
            if oldPath != path {
                events.append(.pathChanged(old: oldPath, new: path))
            }
            pendingDirectModalEvents.removeAll(keepingCapacity: true)
            pendingDirectModalOldPath = nil
            reentrancy.dispatch(events)
        }
    }

    internal func withInnerObservationSource<T>(
        _ source: FlowInnerObservationSource,
        operation: () -> T
    ) -> T {
        reentrancy.withInnerObservationSource(source, operation: operation)
    }
}
