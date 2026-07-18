import Observation

import InnoRouterCore

/// Unified router store that represents push + modal progression as a single
/// array of `RouteStep`s, delegating execution to an inner `NavigationStore`
/// and `ModalStore`.
///
/// `FlowStore` projects the committed navigation + modal state owned by its
/// inner stores into a single array of `RouteStep`s. Consumers dispatch
/// `FlowIntent` values via `send(_:)` or describe the full end state with
/// `FlowPlan` via `apply(_:)`.
///
/// ## Invariants
///
/// 1. Modal steps are always at most one and must be the final element of
///    `path`. `.sheet` / `.cover` in any other position is rejected.
/// 2. `.push` requests are rejected when the current tail is a modal step.
///    Consumers must dismiss first. The reason surfaces through
///    ``FlowEvent/intentRejected(_:_:)`` through the configuration's
///    ``FlowStoreConfiguration/onEvent`` hook as `.pushBlockedByModalTail`.
/// 3. `.pop` / `.dismiss` against an empty path or missing modal tail are
///    silent no-ops (matching `NavigationIntent.back` conventions).
/// 4. `path` is rebuilt from committed inner state after each successful
///    mutation, so middleware rewrites are reflected in the projection.
/// 5. Middleware cancellations from the inner navigation / modal store
///    leave the committed state untouched and emit
///    `.middlewareRejected(debugName:)`.
@Observable
@MainActor
public final class FlowStore<R: Route> {
    /// Canonical projection of the committed navigation prefix and visible
    /// modal tail owned by the inner stores.
    public private(set) var path: [RouteStep<R>]

    /// Inner navigation store that owns stack state for `.push` steps.
    /// Plain `internal`; production code should use ``path`` or the public
    /// state projections on `FlowStore` for reads and
    /// ``FlowStore/send(_:)`` / ``FlowStore/apply(_:)`` for mutations
    /// rather than bypassing FlowStore invariants through this inner store.
    internal let navigationStore: NavigationStore<R>

    /// Inner modal store that owns presentation state for the tail modal step.
    /// Plain `internal`; production code should use ``path`` or the public
    /// state projections on `FlowStore` for reads and
    /// ``FlowStore/send(_:)`` / ``FlowStore/apply(_:)`` for mutations
    /// rather than bypassing FlowStore invariants through this inner store.
    internal let modalStore: ModalStore<R>

    private let queueCoalescePolicy: QueueCoalescePolicy<R>
    private let link: FlowStoreLink<R>
    private let broadcaster: EventBroadcaster<FlowEvent<R>>
    private let eventDispatcher: SerializedEventDispatcher<FlowEvent<R>>
    /// Reentrancy and event-ordering bookkeeping: buffered mutation frames,
    /// dispatch/mutation depth counters, the inner-observation source stack,
    /// and the FIFO reentrant-intent queue all live behind this boundary.
    /// See ``FlowReentrancyCoordinator`` for the protocol they uphold.
    private let reentrancy = FlowReentrancyCoordinator<R>()
    @ObservationIgnored
    private var pendingDirectModalEvents: [FlowEvent<R>] = []
    @ObservationIgnored
    private var pendingDirectModalOldPath: [RouteStep<R>]?
    // `traceRecorder` is `internal` rather than `private` because
    // the public dispatch wrappers in `FlowStore+Public.swift` need
    // to reach it.
    internal var traceRecorder: InternalExecutionTraceRecorder?
    /// Cached intent closure that lives for the lifetime of this store.
    /// Built on first access by ``intentDispatcher`` so SwiftUI hosts do
    /// not allocate a fresh closure on every render.
    @ObservationIgnored
    private var cachedIntentDispatcher: FlowIntentHandler<R>?
    /// Cached low-level navigation adapter published by `FlowHost`.
    ///
    /// The adapter maps every `NavigationIntent` to its equivalent
    /// `FlowIntent` instead of exposing `navigationStore.intentDispatcher`.
    /// This preserves the modal-tail invariant for both named router actions
    /// and explicit `NavigationIntent` sends.
    @ObservationIgnored
    private var cachedNavigationIntentDispatcher: NavigationIntentHandler<R>?
    /// Cached low-level modal adapter published by `FlowHost`.
    ///
    /// The adapter maps every `ModalIntent` to its equivalent `FlowIntent`
    /// instead of exposing `modalStore.intentDispatcher`, keeping all flow
    /// mutations within the same observation and middleware boundary.
    @ObservationIgnored
    private var cachedModalIntentDispatcher: ModalIntentHandler<R>?

    /// A closure that forwards `FlowIntent` values to this store's
    /// ``send(_:)`` entry point.
    ///
    /// Hosts publish this through their unified router authority so descendants
    /// can use ``EnvironmentRouter`` without holding a direct store reference.
    /// The dispatcher is created on first access and reused for the lifetime of
    /// the store, so a SwiftUI host does not allocate a fresh closure on every
    /// render.
    var intentDispatcher: FlowIntentHandler<R> {
        if let cachedIntentDispatcher {
            return cachedIntentDispatcher
        }
        let dispatcher: FlowIntentHandler<R> = { [weak self] intent in
            self?.send(intent)
        }
        cachedIntentDispatcher = dispatcher
        return dispatcher
    }

    /// Navigation-intent adapter used by `FlowHost`.
    ///
    /// Internal by design: ``EnvironmentRouter`` exposes the public action,
    /// while the host ensures the request still enters through
    /// `FlowStore.send(_:)`.
    internal var navigationIntentDispatcher: NavigationIntentHandler<R> {
        if let cachedNavigationIntentDispatcher {
            return cachedNavigationIntentDispatcher
        }
        let dispatcher: NavigationIntentHandler<R> = { [weak self] intent in
            self?.send(Self.flowIntent(for: intent))
        }
        cachedNavigationIntentDispatcher = dispatcher
        return dispatcher
    }

    /// Modal-intent adapter used by `FlowHost`.
    ///
    /// Internal by design: ``EnvironmentRouter`` exposes the public action,
    /// while the host keeps the inner `ModalStore` inaccessible as a mutation
    /// authority.
    internal var modalIntentDispatcher: ModalIntentHandler<R> {
        if let cachedModalIntentDispatcher {
            return cachedModalIntentDispatcher
        }
        let dispatcher: ModalIntentHandler<R> = { [weak self] intent in
            self?.send(Self.flowIntent(for: intent))
        }
        cachedModalIntentDispatcher = dispatcher
        return dispatcher
    }

    /// Exhaustive projection used by the navigation environment adapter.
    nonisolated internal static func flowIntent(
        for intent: NavigationIntent<R>
    ) -> FlowIntent<R> {
        switch intent {
        case .go(let route):
            return .push(route)
        case .goMany(let routes):
            return .pushMany(routes)
        case .back:
            return .pop
        case .backBy(let count):
            return .popCount(count)
        case .backTo(let route):
            return .popTo(route)
        case .backToRoot:
            return .popToRoot
        case .replaceStack(let routes):
            return .replaceStack(routes)
        case .backOrPush(let route):
            return .backOrPush(route)
        case .pushUniqueRoot(let route):
            return .pushUniqueRoot(route)
        }
    }

    /// Exhaustive projection used by the modal environment adapter.
    nonisolated internal static func flowIntent(
        for intent: ModalIntent<R>
    ) -> FlowIntent<R> {
        switch intent {
        case .present(let route, style: .sheet):
            return .presentSheet(route)
        case .present(let route, style: .fullScreenCover):
            return .presentCover(route)
        case .dismiss:
            return .dismiss
        case .dismissAll:
            return .dismissAll
        }
    }

    /// A multicast `AsyncStream` that emits every observation event the
    /// flow store and its inner navigation / modal stores produce —
    /// `.pathChanged` and `.intentRejected` from the flow level, plus
    /// `.navigation(...)` and `.modal(...)` wrappers around the inner
    /// stores' events — in the same order as the synchronous
    /// ``FlowStoreConfiguration/onEvent`` callback.
    ///
    /// This lets a single subscriber assert the complete chain
    /// triggered by one `FlowIntent` (including middleware
    /// cancellation paths) without wiring separate inner-store and
    /// flow-level callbacks.
    public var events: AsyncStream<FlowEvent<R>> {
        broadcaster.stream()
    }

    /// Creates a new flow store.
    /// - Parameters:
    ///   - initial: Initial flow path. If it contains a tail modal step, that
    ///     step is seeded as `modalStore.currentPresentation`.
    ///   - configuration: Flow, navigation, and modal observation hooks.
    public init(
        initial: [RouteStep<R>] = [],
        configuration: FlowStoreConfiguration<R> = .init()
    ) {
        let validatedInitial = Self.validatedInitial(initial)

        let link = FlowStoreLink<R>()

        let userNavigationOnEvent = configuration.navigation.onEvent
        let userModalOnEvent = configuration.modal.onEvent

        var navigationConfiguration = configuration.navigation
        navigationConfiguration.onEvent = { event in
            guard let owner = link.owner else {
                userNavigationOnEvent?(event)
                return
            }
            owner.withInnerObservationSource(.navigation) {
                owner.handleNavigationStoreEvent(event)
                userNavigationOnEvent?(event)
            }
        }
        var modalConfiguration = configuration.modal
        modalConfiguration.onEvent = { event in
            guard let owner = link.owner else {
                userModalOnEvent?(event)
                return
            }
            owner.withInnerObservationSource(.modal) {
                owner.handleModalStoreEvent(event)
                userModalOnEvent?(event)
            }
        }
        let broadcaster = EventBroadcaster<FlowEvent<R>>(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        let onEvent = configuration.onEvent
        let eventDispatcher = SerializedEventDispatcher<FlowEvent<R>> { event in
            onEvent?(event)
            broadcaster.broadcast(event)
        }

        let (pushRoutes, modalTail) = Self.decompose(validatedInitial)
        let initialStack = RouteStack<R>(path: pushRoutes)
        let modalPresentation = modalTail.map { Self.presentation(for: $0) }

        self.navigationStore = NavigationStore(
            initial: initialStack,
            configuration: navigationConfiguration
        )
        self.modalStore = ModalStore(
            currentPresentation: modalPresentation,
            configuration: modalConfiguration
        )
        self.path = FlowProjection(
            pushRoutes: self.navigationStore.state.path,
            currentPresentation: self.modalStore.currentPresentation,
            queuedPresentations: self.modalStore.queuedPresentations
        ).path
        self.queueCoalescePolicy = configuration.queueCoalescePolicy
        self.link = link
        self.broadcaster = broadcaster
        self.eventDispatcher = eventDispatcher
        self.traceRecorder = nil
        self.link.owner = self
        reentrancy.currentPath = { [weak self] in self?.path ?? [] }
        reentrancy.resend = { [weak self] intent in self?.send(intent) }
        reentrancy.deliver = { [eventDispatcher] events in
            eventDispatcher.emit(contentsOf: events)
        }
    }

    /// Creates a new flow store after validating the supplied initial path.
    ///
    /// The default ``init(initial:configuration:)`` remains permissive for
    /// source compatibility and coerces invalid initial paths to an empty
    /// state. Use this initializer when the path comes from an external
    /// source such as state restoration, a deep-link handoff, or a network
    /// payload and invalid input should be reported immediately.
    ///
    /// - Throws: ``FlowPlanValidationError`` describing the first invariant
    ///   violation in `initial`.
    public convenience init(
        validating initial: [RouteStep<R>],
        configuration: FlowStoreConfiguration<R> = .init()
    ) throws {
        try FlowPlan<R>.validate(initial)
        self.init(initial: initial, configuration: configuration)
    }

    // MARK: - Public API

    /// Dispatches a `FlowIntent`, delegating to inner stores after validating
    /// the request against FlowStore invariants.
    // Note: `send(_:)` and `apply(_:)` live in
    // `FlowStore+Public.swift`.

    func installTraceRecorder(_ recorder: InternalExecutionTraceRecorder?) {
        self.traceRecorder = recorder
        navigationStore.installTraceRecorder(recorder)
        modalStore.installTraceRecorder(recorder)
    }

    /// Plans and commits one intent inside the same mutation boundary.
    ///
    /// Middleware runs while `mutationPlan(for:)` is built. Keeping planning
    /// inside this boundary ensures a middleware that synchronously calls
    /// `send(_:)` cannot commit against the same pre-mutation snapshot and be
    /// overwritten by the outer preview. Those nested sends are queued by
    /// `deferReentrantIntentIfNeeded(_:)` and drain FIFO after this complete
    /// plan has committed and delivered its events.
    @discardableResult
    internal func dispatch(_ intent: FlowIntent<R>) -> FlowPlanApplyResult<R> {
        withFlowMutationBoundary {
            applyWithinFlowMutationBoundary(mutationPlan(for: intent), intent: intent)
        }
    }

    private func applyWithinFlowMutationBoundary(
        _ plan: FlowMutationPlan<R>,
        intent: FlowIntent<R>
    ) -> FlowPlanApplyResult<R> {
        let handlesInnerLifecycle = plan.navigationJournal != nil
            || !plan.discardedNavigationJournals.isEmpty
            || !plan.modalJournals.isEmpty
            || !plan.discardedModalJournals.isEmpty
            || !plan.modalCancellationJournals.isEmpty
        if handlesInnerLifecycle {
            beginBufferingInnerEvents(from: plan.oldPath)
        }

        if handlesInnerLifecycle {
            withInternalMutation {
                for journal in plan.discardedNavigationJournals {
                    navigationStore.discardFlowPreview(journal)
                }
                if let navigationJournal = plan.navigationJournal {
                    _ = navigationStore.commitFlowPreview(navigationJournal)
                }
                for journal in plan.discardedModalJournals {
                    modalStore.discardFlowPreview(journal)
                }
                modalStore.commitFlowPreviews(plan.modalJournals)
                for journal in plan.modalCancellationJournals {
                    _ = modalStore.commitFlowCancellation(journal)
                }
            }
        }

        if handlesInnerLifecycle {
            syncPathFromStoresWithoutEmitting()
            finishBufferingInnerEvents()
        } else {
            syncPathFromStores(from: plan.oldPath)
        }

        if let rejectionReason = plan.rejectionReason {
            emitIntentRejected(
                intent,
                reason: rejectionReason,
                applyQueueCoalescePolicy: plan.queueCoalescePolicyEligible
            )
            return .rejected(currentPath: path, reason: rejectionReason)
        }

        return .applied(path: path)
    }

    // MARK: - Reverse sync

    private func handleNavigationStoreEvent(_ event: NavigationEvent<R>) {
        if reentrancy.isApplyingInternalMutation {
            precondition(
                reentrancy.isBuffering,
                "FlowStore navigation event escaped its mutation buffer."
            )
        }
        guard case .changed(_, let newStack) = event else {
            emitFlowEvent(.navigation(event))
            return
        }

        let oldPath = path
        path = FlowProjection(
            pushRoutes: newStack.path,
            currentPresentation: modalStore.currentPresentation,
            queuedPresentations: modalStore.queuedPresentations
        ).path

        var events: [FlowEvent<R>] = [.navigation(event)]
        if !reentrancy.isBuffering, oldPath != path {
            events.append(.pathChanged(old: oldPath, new: path))
        }
        emitFlowEvents(events)
    }

    private func handleModalStoreEvent(_ event: ModalEvent<R>) {
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

    private func withInnerObservationSource<T>(
        _ source: FlowInnerObservationSource,
        operation: () -> T
    ) -> T {
        reentrancy.withInnerObservationSource(source, operation: operation)
    }

    // MARK: - Helpers

    private func emitPathChangedIfNeeded(from oldPath: [RouteStep<R>]) {
        guard oldPath != path else { return }
        emitFlowEvent(.pathChanged(old: oldPath, new: path))
    }

    internal func emitIntentRejected(
        _ intent: FlowIntent<R>,
        reason: FlowRejectionReason,
        applyQueueCoalescePolicy: Bool
    ) {
        if applyQueueCoalescePolicy {
            applyQueueCoalescePolicyIfNeeded(intent: intent, reason: reason)
        }
        emitFlowEvent(.intentRejected(intent, reason))
    }

    private func emitFlowEvent(_ event: FlowEvent<R>) {
        emitFlowEvents([event])
    }

    private func emitFlowEvents(_ events: [FlowEvent<R>]) {
        reentrancy.bufferOrDispatch(events)
    }

    /// Defers only fire-and-forget `send(_:)` intents. Public `apply(_:)`
    /// returns the mutation result synchronously, so routing it through this
    /// queue would require fabricating a result before the plan executes.
    internal func deferReentrantIntentIfNeeded(_ intent: FlowIntent<R>) -> Bool {
        if reentrancy.isApplyingFlowMutation || reentrancy.isApplyingInternalMutation {
            reentrancy.enqueueReentrantIntent(intent)
            return true
        }

        switch reentrancy.innerObservationSource {
        case .navigation:
            navigationStore.performAfterObservationDelivery { [weak self] in
                self?.send(intent)
            }
            return true
        case .modal:
            modalStore.performAfterObservationDelivery { [weak self] in
                self?.send(intent)
            }
            return true
        case nil:
            break
        }

        guard reentrancy.isDispatchingFlowEvents else { return false }
        reentrancy.enqueueReentrantIntent(intent)
        return true
    }

    /// A result-returning `apply(_:)` cannot be deferred without claiming a
    /// mutation completed before it actually ran. Reject it while any Flow or
    /// inner-store observer is synchronously delivering an event; callers that
    /// need a reentrant reset can use `send(.reset(...))`, which is queued.
    internal func rejectReentrantApplyIfNeeded() -> FlowPlanApplyResult<R>? {
        guard reentrancy.isApplyingFlowMutation
            || reentrancy.isApplyingInternalMutation
            || reentrancy.isObservingInnerStore
            || reentrancy.isDispatchingFlowEvents
        else { return nil }

        return .rejected(currentPath: path, reason: .reentrantApply)
    }

    private func applyQueueCoalescePolicyIfNeeded(
        intent: FlowIntent<R>,
        reason: FlowRejectionReason
    ) {
        // Only middleware-rejected commands engage the policy. Other
        // rejections (`.invalidResetPath`, `.pushBlockedByModalTail`)
        // are caller errors and should not silently mutate the modal
        // queue.
        guard case .middlewareRejected = reason else { return }

        let action: QueueCoalescePolicy<R>.Action
        switch queueCoalescePolicy {
        case .preserve:
            return
        case .dropQueued:
            action = .dropQueued
        case .custom(let resolve):
            action = resolve(intent, reason)
        }

        guard action == .dropQueued else { return }
        guard
            modalStore.currentPresentation != nil
                || !modalStore.queuedPresentations.isEmpty
        else { return }

        let oldPath = path
        beginBufferingInnerEvents(from: oldPath)
        withInternalMutation {
            _ = modalStore.dismissAll()
        }
        syncPathFromStoresWithoutEmitting()
        finishBufferingInnerEvents()
    }

    internal func beginBufferingInnerEvents(from oldPath: [RouteStep<R>]) {
        reentrancy.beginBufferingFrame(from: oldPath)
    }

    internal func finishBufferingInnerEvents() {
        reentrancy.finishBufferingFrame()
    }

    internal func withInternalMutation<T>(_ body: () -> T) -> T {
        reentrancy.withInternalMutation(body)
    }

    internal func withFlowMutationBoundary<T>(_ body: () -> T) -> T {
        reentrancy.withFlowMutationBoundary(body)
    }

    internal var currentMutationContext: FlowMutationContext {
        FlowMutationContext(
            navigationState: navigationStore.state,
            modalState: modalStore.flowStateSnapshot
        )
    }

    private var currentProjection: FlowProjection {
        currentMutationContext.projection
    }

    internal func syncPathFromStores(from oldPath: [RouteStep<R>]) {
        syncPath(from: oldPath, projection: currentProjection)
    }

    internal func syncPathFromStoresWithoutEmitting() {
        path = currentProjection.path
    }

    private func syncPath(
        from oldPath: [RouteStep<R>],
        projection: FlowProjection
    ) {
        path = projection.path
        emitPathChangedIfNeeded(from: oldPath)
    }

    internal func previewModalReset(
        to modalTail: RouteStep<R>?,
        from initialState: ModalExecutionState<R>
    ) -> ModalPreviewPlan {
        let targetPresentation = modalTail.map(Self.presentation(for:))

        if Self.matchesPresentationSemantics(initialState.currentPresentation, targetPresentation),
            initialState.queuedPresentations.isEmpty {
            return .commit([])
        }

        var journals: [ModalExecutionJournal<R>] = []
        var shadow = initialState

        if shadow.currentPresentation != nil || !shadow.queuedPresentations.isEmpty {
            let dismissJournal = modalStore.previewFlowCommand(.dismissAll, from: shadow)
            if case .cancelled(let reason) = dismissJournal.result {
                return .rejected(
                    reason,
                    discardedJournals: journals,
                    cancellationJournal: dismissJournal
                )
            }
            journals.append(dismissJournal)
            shadow = dismissJournal.stateAfter
        }

        if let targetPresentation {
            let presentJournal = modalStore.previewFlowCommand(.present(targetPresentation), from: shadow)
            if case .cancelled(let reason) = presentJournal.result {
                return .rejected(
                    reason,
                    discardedJournals: journals,
                    cancellationJournal: presentJournal
                )
            }
            journals.append(presentJournal)
        }

        return .commit(journals)
    }

    // Path validation, decomposition, and trace helpers live in
    // `FlowStore+PathHelpers.swift` so this file stays focused on
    // the `Observable` projection + intent dispatch surface.

    internal struct FlowProjection {
        let pushRoutes: [R]
        let currentPresentation: ModalPresentation<R>?
        let queuedPresentations: [ModalPresentation<R>]

        var path: [RouteStep<R>] {
            var projectedPath = pushRoutes.map(RouteStep.push)
            if let currentPresentation {
                projectedPath.append(FlowStore.step(for: currentPresentation))
            }
            return projectedPath
        }
    }

    internal struct FlowMutationContext {
        let navigationState: RouteStack<R>
        let modalState: ModalExecutionState<R>

        var projection: FlowProjection {
            FlowProjection(
                pushRoutes: navigationState.path,
                currentPresentation: modalState.currentPresentation,
                queuedPresentations: modalState.queuedPresentations
            )
        }
    }

    internal enum ModalPreviewPlan {
        case commit([ModalExecutionJournal<R>])
        case rejected(
            ModalCancellationReason<R>,
            discardedJournals: [ModalExecutionJournal<R>],
            cancellationJournal: ModalExecutionJournal<R>
        )
    }
}

@MainActor
private final class FlowStoreLink<R: Route> {
    weak var owner: FlowStore<R>?
}

// MARK: - FlowPlanApplier conformance

extension FlowStore: FlowPlanApplier {
    public typealias RouteType = R
}
