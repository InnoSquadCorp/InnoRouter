import InnoRouterCore

/// Origin of the inner-store observation currently being delivered to
/// `FlowStore`'s event adapters.
enum FlowInnerObservationSource {
    case navigation
    case modal
}

/// Owns `FlowStore`'s reentrancy and event-ordering bookkeeping.
///
/// One complete Flow mutation must (1) buffer the inner navigation/modal
/// events it commits, (2) emit them as one coalesced batch with at most one
/// `.pathChanged` checkpoint per buffered frame, and (3) queue intents sent
/// reentrantly from observer callbacks until the mutation and its event
/// dispatch fully unwind. The depth counters, the frame stack, and the FIFO
/// intent queue that uphold that protocol used to live as loose fields on
/// `FlowStore`; this type owns them behind one boundary so they are only
/// mutable through the paired `with*` scopes and `begin`/`finish` calls,
/// each guarded by a release-mode `precondition` so an imbalance surfaces
/// immediately instead of silently inverting an invariant.
///
/// Every depth counter is a counter rather than a Bool because nested
/// invocations (a FlowStore-driven inner-store mutation that itself
/// re-enters a scope) must account correctly; "any non-zero depth" is the
/// runtime contract each `is*` accessor exposes.
@MainActor
final class FlowReentrancyCoordinator<R: Route> {
    private struct BufferedFrame {
        var pathChangeBaseline: [RouteStep<R>]
        var events: [FlowEvent<R>]
    }

    private var bufferedFrames: [BufferedFrame] = []
    private var dispatchDepth = 0
    private var queuedReentrantIntents: [FlowIntent<R>] = []
    private var nextQueuedReentrantIntentIndex = 0
    private var isDrainingReentrantIntents = false
    private var sourceStack: [FlowInnerObservationSource] = []
    private var internalMutationDepth = 0
    private var flowMutationDepth = 0

    // Wired once by `FlowStore.init` after `self` is fully initialized.
    // `currentPath` reads the live path projection for checkpointing,
    // `resend` re-enters `FlowStore.send(_:)` for drained intents, and
    // `deliver` hands one coalesced batch to the serialized dispatcher.
    var currentPath: @MainActor () -> [RouteStep<R>] = { [] }
    var resend: @MainActor (FlowIntent<R>) -> Void = { _ in }
    var deliver: @MainActor ([FlowEvent<R>]) -> Void = { _ in }

    // MARK: - State accessors

    /// `true` while `FlowStore` is itself driving an inner-store mutation.
    var isApplyingInternalMutation: Bool { internalMutationDepth > 0 }

    /// `true` until one complete Flow mutation has emitted its committed
    /// inner events, applied rejection-side policies, and emitted rejection.
    var isApplyingFlowMutation: Bool { flowMutationDepth > 0 }

    /// `true` while at least one mutation frame is capturing inner events.
    var isBuffering: Bool { !bufferedFrames.isEmpty }

    /// `true` while a flow-event batch is being synchronously delivered.
    var isDispatchingFlowEvents: Bool { dispatchDepth > 0 }

    /// The inner store whose observation callback is currently on the stack.
    var innerObservationSource: FlowInnerObservationSource? { sourceStack.last }

    /// `true` while any inner-store observation callback is on the stack.
    var isObservingInnerStore: Bool { !sourceStack.isEmpty }

    // MARK: - Scopes

    func withInternalMutation<T>(_ body: () -> T) -> T {
        internalMutationDepth += 1
        defer {
            internalMutationDepth -= 1
            precondition(
                internalMutationDepth >= 0,
                "FlowStore.withInternalMutation depth counter underflowed — invariant break."
            )
            if internalMutationDepth == 0 {
                drainReentrantIntents()
            }
        }
        return body()
    }

    func withFlowMutationBoundary<T>(_ body: () -> T) -> T {
        flowMutationDepth += 1
        defer {
            flowMutationDepth -= 1
            precondition(
                flowMutationDepth >= 0,
                "FlowStore mutation boundary depth counter underflowed — invariant break."
            )
            if flowMutationDepth == 0 {
                drainReentrantIntents()
            }
        }
        return body()
    }

    func withInnerObservationSource<T>(
        _ source: FlowInnerObservationSource,
        operation: () -> T
    ) -> T {
        sourceStack.append(source)
        defer { sourceStack.removeLast() }
        return operation()
    }

    // MARK: - Buffered frames

    func beginBufferingFrame(from oldPath: [RouteStep<R>]) {
        checkpointBufferedPathChangeIfNeeded()
        bufferedFrames.append(
            BufferedFrame(
                pathChangeBaseline: oldPath,
                events: []
            )
        )
    }

    func finishBufferingFrame() {
        precondition(
            !bufferedFrames.isEmpty,
            "FlowStore inner-event buffer underflowed — invariant break."
        )
        checkpointBufferedPathChangeIfNeeded()
        let completedFrame = bufferedFrames.removeLast()

        guard !bufferedFrames.isEmpty else {
            dispatch(completedFrame.events)
            drainReentrantIntents()
            return
        }

        let parentIndex = bufferedFrames.count - 1
        bufferedFrames[parentIndex].events.append(contentsOf: completedFrame.events)
        bufferedFrames[parentIndex].pathChangeBaseline = currentPath()
    }

    private func checkpointBufferedPathChangeIfNeeded() {
        guard !bufferedFrames.isEmpty else { return }
        let index = bufferedFrames.count - 1
        let oldPath = bufferedFrames[index].pathChangeBaseline
        let path = currentPath()
        guard oldPath != path else { return }
        bufferedFrames[index].events.append(
            .pathChanged(old: oldPath, new: path)
        )
        bufferedFrames[index].pathChangeBaseline = path
    }

    // MARK: - Event delivery

    /// Appends `events` to the innermost buffered frame, or delivers them
    /// immediately when no mutation frame is capturing.
    func bufferOrDispatch(_ events: [FlowEvent<R>]) {
        guard !events.isEmpty else { return }
        guard !bufferedFrames.isEmpty else {
            dispatch(events)
            return
        }
        bufferedFrames[bufferedFrames.count - 1].events.append(contentsOf: events)
    }

    func dispatch(_ events: [FlowEvent<R>]) {
        guard !events.isEmpty else { return }
        dispatchDepth += 1
        defer {
            dispatchDepth -= 1
            precondition(
                dispatchDepth >= 0,
                "FlowStore event-dispatch depth counter underflowed — invariant break."
            )
            if dispatchDepth == 0 {
                drainReentrantIntents()
            }
        }
        deliver(events)
    }

    // MARK: - Reentrant intents

    func enqueueReentrantIntent(_ intent: FlowIntent<R>) {
        queuedReentrantIntents.append(intent)
    }

    private func drainReentrantIntents() {
        guard flowMutationDepth == 0 else { return }
        guard internalMutationDepth == 0 else { return }
        guard bufferedFrames.isEmpty else { return }
        guard dispatchDepth == 0 else { return }
        guard !isDrainingReentrantIntents else { return }
        guard nextQueuedReentrantIntentIndex < queuedReentrantIntents.count else { return }

        isDrainingReentrantIntents = true
        defer {
            queuedReentrantIntents.removeAll(keepingCapacity: true)
            nextQueuedReentrantIntentIndex = 0
            isDrainingReentrantIntents = false
        }

        while nextQueuedReentrantIntentIndex < queuedReentrantIntents.count {
            let intent = queuedReentrantIntents[nextQueuedReentrantIntentIndex]
            nextQueuedReentrantIntentIndex += 1
            resend(intent)
        }
    }
}
