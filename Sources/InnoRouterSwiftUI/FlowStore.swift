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
///    `FlowStoreConfiguration.onIntentRejected` as
///    `.pushBlockedByModalTail`.
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
    /// Plain `internal`; production code should use the public
    /// ``FlowStateReading`` projection for reads and
    /// ``FlowStore/send(_:)`` / ``FlowStore/apply(_:)`` for mutations
    /// rather than bypassing FlowStore invariants through this inner store.
    internal let navigationStore: NavigationStore<R>

    /// Inner modal store that owns presentation state for the tail modal step.
    /// Plain `internal`; production code should use the public
    /// ``FlowStateReading`` projection for reads and
    /// ``FlowStore/send(_:)`` / ``FlowStore/apply(_:)`` for mutations
    /// rather than bypassing FlowStore invariants through this inner store.
    internal let modalStore: ModalStore<R>

    private let onPathChanged: (@MainActor @Sendable ([RouteStep<R>], [RouteStep<R>]) -> Void)?
    private let onIntentRejected: (@MainActor @Sendable (FlowIntent<R>, FlowRejectionReason) -> Void)?
    private let telemetrySink: AnyFlowTelemetrySink<R>?
    private let queueCoalescePolicy: QueueCoalescePolicy<R>
    private let link: FlowStoreLink<R>
    private let broadcaster: EventBroadcaster<FlowEvent<R>>
    // `traceRecorder` is `internal` rather than `private` because
    // the public dispatch wrappers in `FlowStore+Public.swift` need
    // to reach it.
    internal var traceRecorder: InternalExecutionTraceRecorder?
    /// Cached intent closure that lives for the lifetime of this store.
    /// Built on first access by ``intentDispatcher`` so SwiftUI hosts do
    /// not allocate a fresh closure on every render.
    @ObservationIgnored
    private var cachedIntentDispatcher: FlowIntentHandler<R>?

    // Bookkeeping toggled while FlowStore drives its own inner stores, so
    // observer callbacks can distinguish user / system-initiated changes.
    //
    // Implemented as a depth counter rather than a Bool so nested
    // invocations (FlowStore-driven inner-store mutation that itself
    // re-enters withInternalMutation) account correctly. The
    // counter is read through ``isApplyingInternalMutation`` to keep
    // every call site syntactically identical to the previous Bool.
    // The runtime contract — "any non-zero depth means FlowStore is
    // driving the inner stores" — is enforced through a release-mode
    // `precondition` on decrement so an underflow surfaces immediately
    // instead of silently inverting the guard.
    private var mutationDepth: Int = 0

    /// `true` while `FlowStore` is itself driving an inner-store
    /// mutation. The four `guard` sites in the inner-store reverse-
    /// sync callbacks read this to skip the projection refresh that
    /// would otherwise loop back through the path projection.
    private var isApplyingInternalMutation: Bool { mutationDepth > 0 }

    /// A closure that forwards `FlowIntent` values to this store's
    /// ``send(_:)`` entry point.
    ///
    /// Hosts publish this through the SwiftUI environment so descendants can
    /// use ``EnvironmentFlowIntent`` to dispatch view-layer intents without
    /// holding a direct store reference. The dispatcher is created on first
    /// access and reused for the lifetime of the store, so a SwiftUI host
    /// does not allocate a fresh closure on every render.
    public var intentDispatcher: @MainActor @Sendable (FlowIntent<R>) -> Void {
        if let cachedIntentDispatcher {
            return cachedIntentDispatcher
        }
        let dispatcher: FlowIntentHandler<R> = { [weak self] intent in
            self?.send(intent)
        }
        cachedIntentDispatcher = dispatcher
        return dispatcher
    }

    /// A multicast `AsyncStream` that emits every observation event the
    /// flow store and its inner navigation / modal stores produce —
    /// `.pathChanged` and `.intentRejected` from the flow level, plus
    /// `.navigation(...)` and `.modal(...)` wrappers around the inner
    /// stores' events — in the same order as the matching callbacks
    /// fire.
    ///
    /// This lets a single subscriber assert the complete chain
    /// triggered by one `FlowIntent` (including middleware
    /// cancellation paths) without wiring the ten individual
    /// navigation + modal + flow callbacks.
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

        let userNavOnChange = configuration.navigation.onChange
        let userNavOnBatchExecuted = configuration.navigation.onBatchExecuted
        let userNavOnTransactionExecuted = configuration.navigation.onTransactionExecuted
        let userNavOnMiddlewareMutation = configuration.navigation.onMiddlewareMutation
        let userNavOnPathMismatch = configuration.navigation.onPathMismatch
        let userModalOnPresented = configuration.modal.onPresented
        let userModalOnDismissed = configuration.modal.onDismissed
        let userModalOnReplaced = configuration.modal.onReplaced
        let userModalOnQueueChanged = configuration.modal.onQueueChanged
        let userModalOnMiddlewareMutation = configuration.modal.onMiddlewareMutation
        let userModalOnCommandIntercepted = configuration.modal.onCommandIntercepted

        let composedNavOnChange: @MainActor @Sendable (RouteStack<R>, RouteStack<R>) -> Void = { old, new in
            userNavOnChange?(old, new)
            link.owner?.emitNavigationEvent(.changed(from: old, to: new))
            link.owner?.handleNavigationStoreChange(from: old, to: new)
        }
        let composedNavOnBatchExecuted: @MainActor @Sendable (NavigationBatchResult<R>) -> Void = { batch in
            userNavOnBatchExecuted?(batch)
            link.owner?.emitNavigationEvent(.batchExecuted(batch))
        }
        let composedNavOnTransactionExecuted: @MainActor @Sendable (NavigationTransactionResult<R>) -> Void = { transaction in
            userNavOnTransactionExecuted?(transaction)
            link.owner?.emitNavigationEvent(.transactionExecuted(transaction))
        }
        let composedNavOnMiddlewareMutation: @MainActor @Sendable (MiddlewareMutationEvent<R>) -> Void = { event in
            userNavOnMiddlewareMutation?(event)
            link.owner?.emitNavigationEvent(.middlewareMutation(event))
        }
        let composedNavOnPathMismatch: @MainActor @Sendable (NavigationPathMismatchEvent<R>) -> Void = { event in
            userNavOnPathMismatch?(event)
            link.owner?.emitNavigationEvent(.pathMismatch(event))
        }
        let composedModalOnPresented: @MainActor @Sendable (ModalPresentation<R>) -> Void = { presentation in
            userModalOnPresented?(presentation)
            link.owner?.emitModalEvent(.presented(presentation))
            link.owner?.handleModalStorePresentation(presentation)
        }
        let composedModalOnDismissed: @MainActor @Sendable (ModalPresentation<R>, ModalDismissalReason) -> Void = { presentation, reason in
            userModalOnDismissed?(presentation, reason)
            link.owner?.emitModalEvent(.dismissed(presentation, reason: reason))
            link.owner?.handleModalStoreDismissal(presentation: presentation, reason: reason)
        }
        let composedModalOnReplaced: @MainActor @Sendable (ModalPresentation<R>, ModalPresentation<R>) -> Void = { old, new in
            userModalOnReplaced?(old, new)
            link.owner?.emitModalEvent(.replaced(old: old, new: new))
        }
        let composedModalOnQueueChanged: @MainActor @Sendable ([ModalPresentation<R>], [ModalPresentation<R>]) -> Void = { old, new in
            userModalOnQueueChanged?(old, new)
            link.owner?.emitModalEvent(.queueChanged(old: old, new: new))
        }
        let composedModalOnMiddlewareMutation: @MainActor @Sendable (ModalMiddlewareMutationEvent<R>) -> Void = { event in
            userModalOnMiddlewareMutation?(event)
            link.owner?.emitModalEvent(.middlewareMutation(event))
        }
        let composedModalOnCommandIntercepted: @MainActor @Sendable (ModalCommand<R>, ModalExecutionResult<R>) -> Void = { command, result in
            userModalOnCommandIntercepted?(command, result)
            link.owner?.emitModalEvent(.commandIntercepted(command: command, result: result))
            switch result {
            case .executed(.replaceCurrent):
                link.owner?.handleModalStoreReplacement()
            case .executed(.present),
                 .executed(.dismissCurrent),
                 .executed(.dismissAll),
                 .queued,
                 .cancelled,
                 .noop:
                break
            }
        }

        let navConfig = NavigationStoreConfiguration<R>(
            engine: configuration.navigation.engine,
            middlewares: configuration.navigation.middlewares,
            routeStackValidator: configuration.navigation.routeStackValidator,
            pathMismatchPolicy: configuration.navigation.pathMismatchPolicy,
            logger: configuration.navigation.logger,
            telemetrySink: configuration.navigation.telemetrySink,
            onChange: composedNavOnChange,
            onBatchExecuted: composedNavOnBatchExecuted,
            onTransactionExecuted: composedNavOnTransactionExecuted,
            onMiddlewareMutation: composedNavOnMiddlewareMutation,
            onPathMismatch: composedNavOnPathMismatch,
            eventBufferingPolicy: configuration.navigation.eventBufferingPolicy,
            pathReconciler: configuration.navigation.pathReconciler
        )

        let modalConfig = ModalStoreConfiguration<R>(
            logger: configuration.modal.logger,
            telemetrySink: configuration.modal.telemetrySink,
            middlewares: configuration.modal.middlewares,
            onPresented: composedModalOnPresented,
            onDismissed: composedModalOnDismissed,
            onReplaced: composedModalOnReplaced,
            onQueueChanged: composedModalOnQueueChanged,
            onMiddlewareMutation: composedModalOnMiddlewareMutation,
            onCommandIntercepted: composedModalOnCommandIntercepted,
            eventBufferingPolicy: configuration.modal.eventBufferingPolicy,
            queueCancellationPolicy: configuration.modal.queueCancellationPolicy
        )

        let (pushRoutes, modalTail) = Self.decompose(validatedInitial)
        let initialStack = RouteStack<R>(path: pushRoutes)
        let modalPresentation = modalTail.map { Self.presentation(for: $0) }

        self.navigationStore = NavigationStore(
            initial: initialStack,
            configuration: navConfig
        )
        self.modalStore = ModalStore(
            currentPresentation: modalPresentation,
            configuration: modalConfig
        )
        self.path = FlowProjection(
            pushRoutes: self.navigationStore.state.path,
            currentPresentation: self.modalStore.currentPresentation,
            queuedPresentations: self.modalStore.queuedPresentations
        ).path
        self.onPathChanged = configuration.onPathChanged
        self.onIntentRejected = configuration.onIntentRejected
        self.telemetrySink = configuration.telemetrySink
        self.queueCoalescePolicy = configuration.queueCoalescePolicy
        self.link = link
        let broadcaster = EventBroadcaster<FlowEvent<R>>(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        self.broadcaster = broadcaster
        self.traceRecorder = nil
        self.link.owner = self
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

    // MARK: - Dispatch

    // `mutationPlan(for:)` and the `apply(_:intent:)` overload are
    // `internal` rather than `private` because the public entry
    // points (`send(_:)`, `apply(_:)`) live in
    // `FlowStore+Public.swift`. Access stays inside the
    // InnoRouterSwiftUI module.
    internal func mutationPlan(for intent: FlowIntent<R>) -> FlowMutationPlan<R> {
        let context = currentMutationContext
        switch intent {
        case .push(let route):
            return dispatchPush(route, in: context)
        case .presentSheet(let route):
            return dispatchModal(step: .sheet(route), in: context)
        case .presentCover(let route):
            return dispatchModal(step: .cover(route), in: context)
        case .pop:
            return dispatchPop(in: context)
        case .dismiss:
            return dispatchDismiss(in: context)
        case .reset(let steps):
            return dispatchReset(steps, in: context)
        case .replaceStack(let routes):
            return dispatchReplaceStack(routes, in: context)
        case .backOrPush(let route):
            return dispatchBackOrPush(route, in: context)
        case .pushUniqueRoot(let route):
            return dispatchPushUniqueRoot(route, in: context)
        case .backOrPushDismissingModal(let route):
            return dispatchDismissingModal(in: context) { updatedContext in
                self.dispatchBackOrPush(route, in: updatedContext)
            }
        case .pushUniqueRootDismissingModal(let route):
            return dispatchDismissingModal(in: context) { updatedContext in
                self.dispatchPushUniqueRoot(route, in: updatedContext)
            }
        }
    }

    @discardableResult
    internal func apply(_ plan: FlowMutationPlan<R>, intent: FlowIntent<R>) -> FlowPlanApplyResult<R> {
        if let navigationJournal = plan.navigationJournal {
            withInternalMutation {
                _ = navigationStore.commitFlowPreview(navigationJournal)
                modalStore.commitFlowPreviews(plan.modalJournals)
            }
        } else if !plan.modalJournals.isEmpty {
            withInternalMutation {
                modalStore.commitFlowPreviews(plan.modalJournals)
            }
        }

        syncPathFromStores(from: plan.oldPath)

        if let rejectionReason = plan.rejectionReason {
            emitIntentRejected(
                intent,
                reason: rejectionReason,
                applyQueueCoalescePolicy: plan.queueCoalescePolicyEligible
            )
            return .rejected(currentPath: path)
        }

        return .applied(path: path)
    }

    private func dispatchPush(_ route: R, in context: FlowMutationContext) -> FlowMutationPlan<R> {
        if context.projection.currentPresentation != nil {
            return .rejected(oldPath: path, reason: .pushBlockedByModalTail)
        }

        let journal = navigationStore.previewFlowCommand(.push(route), from: context.navigationState)
        if case .cancelled(let reason) = journal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                queueCoalescePolicyEligible: true
            )
        }

        return .commit(oldPath: path, navigationJournal: journal)
    }

    private func dispatchModal(
        step: RouteStep<R>,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        let journal = modalStore.previewFlowCommand(
            .present(Self.presentation(for: step)),
            from: context.modalState
        )

        if case .cancelled(let reason) = journal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason))
            )
        }

        return .commit(oldPath: path, modalJournals: [journal])
    }

    private func dispatchPop(in context: FlowMutationContext) -> FlowMutationPlan<R> {
        guard !context.navigationState.path.isEmpty else { return .commit(oldPath: path) }
        guard context.projection.currentPresentation == nil else { return .commit(oldPath: path) }

        let journal = navigationStore.previewFlowCommand(.pop, from: context.navigationState)
        if case .cancelled(let reason) = journal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                queueCoalescePolicyEligible: true
            )
        }

        return .commit(oldPath: path, navigationJournal: journal)
    }

    private func dispatchDismiss(in context: FlowMutationContext) -> FlowMutationPlan<R> {
        guard context.projection.currentPresentation != nil else { return .commit(oldPath: path) }
        let journal = modalStore.previewFlowCommand(
            .dismissCurrent(reason: .dismiss),
            from: context.modalState
        )
        if case .cancelled(let reason) = journal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason))
            )
        }

        return .commit(oldPath: path, modalJournals: [journal])
    }

    @discardableResult
    private func dispatchReset(
        _ steps: [RouteStep<R>],
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        guard Self.isValidPath(steps) else {
            return .rejected(oldPath: path, reason: .invalidResetPath)
        }

        let (pushRoutes, modalTail) = Self.decompose(steps)

        let navJournal = navigationStore.previewFlowCommand(
            .replace(pushRoutes),
            from: context.navigationState
        )
        if case .cancelled(let reason) = navJournal.result {
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                queueCoalescePolicyEligible: true
            )
        }

        let modalPlan = previewModalReset(to: modalTail, from: context.modalState)
        switch modalPlan {
        case .rejected(let reason):
            return .rejected(
                oldPath: path,
                reason: .middlewareRejected(debugName: Self.debugName(from: reason))
            )
        case .commit(let modalJournals):
            return .commit(
                oldPath: path,
                navigationJournal: navJournal,
                modalJournals: modalJournals
            )
        }
    }

    /// Replaces the navigation push prefix with `routes`, dropping any
    /// active modal tail. Routes through `dispatchReset` so the same
    /// invariant validation + middleware pipeline applies.
    private func dispatchReplaceStack(
        _ routes: [R],
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        let steps = routes.map(RouteStep<R>.push)
        return dispatchReset(steps, in: context)
    }

    /// Pops the navigation stack back to `route` if it's already in the
    /// stack. Otherwise falls through to `dispatchPush`, which honours
    /// the modal-tail invariant by rejecting with
    /// `.pushBlockedByModalTail` when a modal is active.
    private func dispatchBackOrPush(
        _ route: R,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        if context.projection.currentPresentation != nil {
            return .rejected(oldPath: path, reason: .pushBlockedByModalTail)
        }

        if context.navigationState.path.contains(route) {
            let journal = navigationStore.previewFlowCommand(.popTo(route), from: context.navigationState)
            if case .cancelled(let reason) = journal.result {
                return .rejected(
                    oldPath: path,
                    reason: .middlewareRejected(debugName: Self.debugName(from: reason)),
                    queueCoalescePolicyEligible: true
                )
            }
            return .commit(oldPath: path, navigationJournal: journal)
        }
        return dispatchPush(route, in: context)
    }

    /// Silent no-op when the navigation stack already contains `route`.
    /// Otherwise dispatches as `.push(route)`, so a modal tail rejects
    /// the intent with `.pushBlockedByModalTail`.
    private func dispatchPushUniqueRoot(
        _ route: R,
        in context: FlowMutationContext
    ) -> FlowMutationPlan<R> {
        if context.navigationState.path.contains(route) {
            return .commit(oldPath: path)
        }
        return dispatchPush(route, in: context)
    }

    /// Dismisses any active modal tail and then runs `inner`. If
    /// the dismiss is cancelled by middleware, the outer intent is
    /// rejected and `inner` does NOT run. If no modal is active,
    /// `inner` runs directly. Promoting a queued modal does not count
    /// as a successful dismissal for these intents; they only proceed
    /// once the modal tail is fully gone, otherwise the outer intent
    /// is rejected with `.pushBlockedByModalTail`.
    private func dispatchDismissingModal(
        in context: FlowMutationContext,
        inner: (FlowMutationContext) -> FlowMutationPlan<R>
    ) -> FlowMutationPlan<R> {
        guard context.projection.currentPresentation != nil else {
            return inner(context)
        }
        let dismissPlan = dispatchDismiss(in: context)
        if dismissPlan.rejectionReason != nil {
            return dismissPlan
        }
        let promotedPresentation = dismissPlan.modalJournals.last?.stateAfter.currentPresentation
        guard promotedPresentation == nil else {
            return FlowMutationPlan(
                oldPath: path,
                rejectionReason: .pushBlockedByModalTail,
                queueCoalescePolicyEligible: false,
                navigationJournal: nil,
                modalJournals: dismissPlan.modalJournals
            )
        }

        let updatedContext = FlowMutationContext(
            navigationState: context.navigationState,
            modalState: dismissPlan.modalJournals.last?.stateAfter ?? context.modalState
        )
        let innerPlan = inner(updatedContext)
        return FlowMutationPlan(
            oldPath: path,
            rejectionReason: innerPlan.rejectionReason,
            queueCoalescePolicyEligible: innerPlan.queueCoalescePolicyEligible,
            navigationJournal: innerPlan.navigationJournal,
            modalJournals: dismissPlan.modalJournals + innerPlan.modalJournals
        )
    }

    // MARK: - Reverse sync

    private func handleNavigationStoreChange(
        from oldStack: RouteStack<R>,
        to newStack: RouteStack<R>
    ) {
        guard !isApplyingInternalMutation else { return }
        syncPath(
            from: path,
            projection: FlowProjection(
                pushRoutes: newStack.path,
                currentPresentation: modalStore.currentPresentation,
                queuedPresentations: modalStore.queuedPresentations
            )
        )
    }

    private func handleModalStoreDismissal(
        presentation: ModalPresentation<R>,
        reason: ModalDismissalReason
    ) {
        guard !isApplyingInternalMutation else { return }
        syncPathFromStores(from: path)
    }

    private func handleModalStorePresentation(_ presentation: ModalPresentation<R>) {
        guard !isApplyingInternalMutation else { return }
        syncPathFromStores(from: path)
    }

    private func handleModalStoreReplacement() {
        guard !isApplyingInternalMutation else { return }
        syncPathFromStores(from: path)
    }

    // MARK: - Helpers

    private func emitPathChangedIfNeeded(from oldPath: [RouteStep<R>]) {
        guard oldPath != path else { return }
        onPathChanged?(oldPath, path)
        emitFlowEvent(.pathChanged(old: oldPath, new: path))
    }

    private func emitNavigationEvent(_ event: NavigationEvent<R>) {
        emitFlowEvent(.navigation(event))
    }

    private func emitModalEvent(_ event: ModalEvent<R>) {
        emitFlowEvent(.modal(event))
    }

    private func emitIntentRejected(
        _ intent: FlowIntent<R>,
        reason: FlowRejectionReason,
        applyQueueCoalescePolicy: Bool
    ) {
        if applyQueueCoalescePolicy {
            applyQueueCoalescePolicyIfNeeded(intent: intent, reason: reason)
        }
        onIntentRejected?(intent, reason)
        emitFlowEvent(.intentRejected(intent, reason))
    }

    private func emitFlowEvent(_ event: FlowEvent<R>) {
        telemetrySink?.record(event)
        broadcaster.broadcast(event)
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

        withInternalMutation {
            modalStore.dismissAll()
        }
        let oldPath = path
        syncPathFromStores(from: oldPath)
    }

    private func withInternalMutation<T>(_ body: () -> T) -> T {
        // The previous Bool flag was not safe under reentrant call
        // sites — a nested invocation would silently restore
        // `false` on the inner `defer` while the outer scope still
        // expected the flag to be set. The depth counter records
        // *how many* nested mutations are in flight; the inner-store
        // reverse-sync guards keep reading
        // ``isApplyingInternalMutation`` (depth > 0) and so behave
        // identically when not nested but stay correct when nested.
        //
        // The release-mode `precondition` on decrement catches an
        // imbalance (decrement without matching increment) loudly
        // instead of letting the counter go negative and quietly
        // re-enabling the reverse-sync guards.
        mutationDepth += 1
        defer {
            mutationDepth -= 1
            precondition(
                mutationDepth >= 0,
                "FlowStore.withInternalMutation depth counter underflowed — invariant break."
            )
        }
        return body()
    }

    private var currentMutationContext: FlowMutationContext {
        FlowMutationContext(
            navigationState: navigationStore.state,
            modalState: modalStore.flowStateSnapshot
        )
    }

    private var currentProjection: FlowProjection {
        currentMutationContext.projection
    }

    private func syncPathFromStores(from oldPath: [RouteStep<R>]) {
        syncPath(from: oldPath, projection: currentProjection)
    }

    private func syncPath(
        from oldPath: [RouteStep<R>],
        projection: FlowProjection
    ) {
        path = projection.path
        emitPathChangedIfNeeded(from: oldPath)
    }

    private func previewModalReset(
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
                return .rejected(reason)
            }
            journals.append(dismissJournal)
            shadow = dismissJournal.stateAfter
        }

        if let targetPresentation {
            let presentJournal = modalStore.previewFlowCommand(.present(targetPresentation), from: shadow)
            if case .cancelled(let reason) = presentJournal.result {
                return .rejected(reason)
            }
            journals.append(presentJournal)
        }

        return .commit(journals)
    }

    // Path validation, decomposition, and trace helpers live in
    // `FlowStore+PathHelpers.swift` so this file stays focused on
    // the `Observable` projection + intent dispatch surface.

    private struct FlowProjection {
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

    private struct FlowMutationContext {
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

    private enum ModalPreviewPlan {
        case commit([ModalExecutionJournal<R>])
        case rejected(ModalCancellationReason<R>)
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
