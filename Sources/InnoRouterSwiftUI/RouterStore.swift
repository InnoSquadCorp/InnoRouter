// MARK: - RouterStore.swift
// InnoRouterSwiftUI - canonical InnoRouter 6 state authority
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation

import InnoRouterCore

/// The single mutable navigation authority for one `@Router` route type.
///
/// Every request is first reduced into a complete candidate value, then offered
/// to policies, and finally committed with one observable state assignment.
/// No mutable router state is held across a suspension.
@MainActor
@Observable
public final class RouterStore<R: Route> {
    /// The complete committed navigation state.
    public var state: RouterState<R> { committedValue.state }

    /// Frozen host contract committed atomically with the navigation value.
    public var hostDescriptor: RouterHostDescriptor<R>? { committedValue.hostDescriptor }

    var committedValue: RouterCommittedValue<R>

    /// Monotonic committed-state revision used for stale-prepare detection.
    public var revision: UInt64 { committedValue.revision }

    /// Payload-safe unresolved requests released by prepare policies.
    public package(set) var deferredTransitions: [RouterDeferredTransition] = []

    @ObservationIgnored
    public let resourceBudget: RouterResourceBudget
    @ObservationIgnored
    let policies: [RouterPolicy<R>]
    @ObservationIgnored
    let authorization: RouterAuthorizationConfiguration<R>?
    @ObservationIgnored
    let schedulingPolicy: RouterSchedulingPolicy
    @ObservationIgnored
    let maximumPendingRequestCount: Int
    @ObservationIgnored
    let requestOverflowStrategy: RouterRequestOverflowStrategy
    @ObservationIgnored
    let policyTimeout: Duration?
    @ObservationIgnored
    let policyOperations: RouterOperationRegistry
    @ObservationIgnored
    let restorationOperations: RouterOperationRegistry
    @ObservationIgnored
    let deferralConfiguration: RouterDeferralConfiguration
    @ObservationIgnored
    let runtimeDependencies: RouterRuntimeDependencies
    @ObservationIgnored
    let broadcaster: EventBroadcaster<RouterEvent<R>>
    @ObservationIgnored
    let requestBroadcaster: EventBroadcaster<RouterRequestObservation<R>>
    @ObservationIgnored
    let onEvent: (@MainActor @Sendable (RouterEvent<R>) -> Void)?
    @ObservationIgnored
    var synchronousEventObservers: [UUID: @MainActor @Sendable (RouterEvent<R>) -> Void] = [:]
    @ObservationIgnored
    var synchronousRequestObservers: [UUID: @MainActor @Sendable (RouterRequestObservation<R>) -> Void] = [:]
    @ObservationIgnored
    var synchronousCancellationObservers: [UUID: @MainActor @Sendable (RouterTransitionID) -> Void] = [:]
    @ObservationIgnored
    var activeTransitionID: RouterTransitionID?
    @ObservationIgnored
    var activeRequestRootID: RouterTransitionID?
    @ObservationIgnored
    var activeRequestKey: RouterRequestKey?
    @ObservationIgnored
    var activeSystemRepairIdentity: RouterSystemRepairIdentity?
    @ObservationIgnored
    var activeQueuedExecutionTask: Task<Void, Never>?
    @ObservationIgnored
    var activePolicyRaces: [RouterTransitionID: RouterTimeoutRace<RouterPolicyDecision>] = [:]
    @ObservationIgnored
    var activeAuthorizationRaces: [RouterTransitionID: RouterTimeoutRace<Bool>] = [:]
    @ObservationIgnored
    var queuedRequests: [QueuedRouterRequest<R>] = []
    @ObservationIgnored
    var queuedSystemRepairs: [QueuedRouterRequest<R>] = []
    @ObservationIgnored
    var cancelledRequestIDs: Set<RouterTransitionID> = []
    @ObservationIgnored
    var requestCompletionWaiters: [
        RouterTransitionID: [CheckedContinuation<Void, Never>]
    ] = [:]
    @ObservationIgnored
    var deferredRequests: [RouterDeferralID: DeferredRouterRequest<R>] = [:]
    @ObservationIgnored
    var deferralExpirationTasks: [RouterDeferralID: RouterDeferralExpiration] = [:]
    @ObservationIgnored
    var scopes: [RouterScopePath: WeakRouterScope<R>] = [:]
    @ObservationIgnored
    var scopeLifetimes: [RouterScopePath: RouterScopeRuntimeLifetime<R>]
    @ObservationIgnored
    var presentationLifetimes: [UUID: RouterPresentationRuntimeLifetime]
    @ObservationIgnored
    var presentationLifetimeObservations: [RouterScopePath: RouterPresentationLifetimeObservation] = [:]
    @ObservationIgnored
    var scopeLifetimeObservations: [RouterScopePath: RouterScopeLifetimeObservation] = [:]
    @ObservationIgnored
    var presentationWaiters: [UUID: AnyRouterPresentationWaiter] = [:]
    @ObservationIgnored
    var presentationRequestIDs: [UUID: Set<RouterTransitionID>] = [:]
    @ObservationIgnored
    package var platformAdaptationHistory = RouterPlatformAdaptationHistory()
    @ObservationIgnored
    var immersiveSpaceLifecycleToken: UUID?
    @ObservationIgnored
    var windowLifecycleTokens: [UUID: UUID]
    @ObservationIgnored
    let sceneRestorationRegistry = RouterSceneRestorationRegistry()

    /// A multicast stream of correlated transition events.
    public var events: AsyncStream<RouterEvent<R>> {
        broadcaster.stream()
    }

    /// Opt-in stream of resource-admitted requests before scheduling or reduction.
    /// Oversized inputs produce only a payload-safe terminal rejection event.
    public var requestObservations: AsyncStream<RouterRequestObservation<R>> {
        requestBroadcaster.stream()
    }

    /// Creates an empty root stack with the library's finite default budget.
    /// This overload has no external state or configuration to validate.
    public convenience init() {
        self.init(validatedState: .rootStack, configuration: .init())
    }

    /// No application state, declaration or configuration is accepted here.
    /// Keeps the empty native stack convenience nonthrowing without a trap.
    package static func makeDefaultHostedStack() -> RouterStore<R> {
        RouterStore(validatedState: .rootStack, configuration: .init(hostDescriptor: .init(
            root: .stack, rootDeclarations: [.init(path: [], meaning: .declarationID("router.root"))]
        )))
    }

    /// Validates resource, structural, and scene-catalog invariants before
    /// creating any scopes or retaining the supplied state.
    public convenience init(
        initialState: RouterState<R>,
        configuration: RouterStoreConfiguration<R> = .init()
    ) throws {
        try configuration.validate()
        try configuration.resourceBudget.validate(initialState)
        try initialState.validate()
        try configuration.hostDescriptor?.validate(initialState, resourceBudget: configuration.resourceBudget)
        if let error = Self.sceneCatalogValidationError(in: initialState) {
            throw error
        }
        self.init(validatedState: initialState, configuration: configuration)
    }

    private init(
        validatedState initialState: RouterState<R>,
        configuration: RouterStoreConfiguration<R>
    ) {
        self.resourceBudget = configuration.resourceBudget
        self.committedValue = .init(state: initialState, hostDescriptor: configuration.hostDescriptor)
        let scopeLifetimes = Self.makeScopeLifetimes(in: initialState)
        self.scopeLifetimes = scopeLifetimes
        self.presentationLifetimes = Self.makePresentationLifetimes(in: initialState, scopes: scopeLifetimes)
        self.policies = configuration.policies
        self.authorization = configuration.authorization
        self.schedulingPolicy = configuration.schedulingPolicy
        self.maximumPendingRequestCount = resourceBudget.maximumPendingRequests
        self.requestOverflowStrategy = configuration.requestOverflowStrategy
        self.policyTimeout = resourceBudget.policyTimeout
        self.policyOperations = RouterOperationRegistry(
            maximumCount: resourceBudget.maximumActivePolicyOperations
        )
        self.restorationOperations = RouterOperationRegistry(
            maximumCount: resourceBudget.maximumActiveRestorationOperations
        )
        var deferrals = configuration.deferrals
        deferrals.maximumPendingCount = resourceBudget.maximumDeferrals
        deferrals.timeToLive = resourceBudget.deferralLifetime
        self.deferralConfiguration = deferrals
        self.runtimeDependencies = configuration.runtimeDependencies
        self.broadcaster = EventBroadcaster(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        self.requestBroadcaster = EventBroadcaster(
            bufferingPolicy: configuration.eventBufferingPolicy
        )
        self.onEvent = configuration.onEvent
        self.windowLifecycleTokens = Dictionary(
            uniqueKeysWithValues: initialState.windows.map { ($0.id, UUID()) }
        )
        self.immersiveSpaceLifecycleToken = initialState.immersiveSpace.map { _ in UUID() }
    }

    /// Creates a root stack after resource admission of its supplied path.
    public convenience init(
        initialPath: [R],
        configuration: RouterStoreConfiguration<R> = .init()
    ) throws {
        try configuration.validate()
        let state = try RouterStateDraft<R>(root: .stack(path: initialPath))
            .build(resourceBudget: configuration.resourceBudget)
        try self.init(initialState: state, configuration: configuration)
    }

    /// Even an empty configured Store uses throwing input admission. A future
    /// configuration can narrow its resources without hiding initialization errors.
    public convenience init(configuration: RouterStoreConfiguration<R>) throws {
        try self.init(initialState: .rootStack, configuration: configuration)
    }

    /// Performs one request through reduce, prepare, stale-check, and commit.
    ///
    /// Requests are serialized by default, so rapid view and system events
    /// retain FIFO ordering while an async policy is suspended. Configure
    /// `.rejectWhileBusy` only when immediate back-pressure is required.
    public func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext = .init()
    ) async -> RouterOutcome<R> {
        await perform(
            action,
            context: context,
            expectedRevision: nil,
            bypassesPolicies: false,
            startingPolicyIndex: 0,
            transitionID: runtimeDependencies.makeTransitionID()
        )
    }

    package func reserveTransitionID() -> RouterTransitionID {
        runtimeDependencies.makeTransitionID()
    }
}

enum RouterExecutionAdmission<R: Route> {
    case action(RouterAction<R>)
    case terminal(RouterOutcome<R>)
}

extension RouterStore {
    func execute(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        bypassesPolicies: Bool,
        startingPolicyIndex: Int,
        transitionID: RouterTransitionID,
        requestRootID: RouterTransitionID,
        requestSemantics: RouterRequestSemantics<R>,
        authorization: RouterRequestAuthorization<R>?,
        lifetimeMutation: RouterScopeLifetimeMutation,
        hostReplacement: RouterHostReplacement<R>?,
        presentationCompletionOwner: RouterPresentationCompletionOwner,
        executionPrecondition: RouterRequestPrecondition<R>?,
        executionPreparation: RouterRequestPreparationBuilder<R>?,
        deferredResumePreparation: RouterDeferredResumePreparationBuilder<R>?
    ) async -> RouterOutcome<R> {
        defer { finishExecution(transitionID) }

        let preparedAction: RouterAction<R>
        switch admitExecution(
            action,
            context: context,
            expectedRevision: expectedRevision,
            transitionID: transitionID,
            executionPrecondition: executionPrecondition,
            executionPreparation: executionPreparation
        ) {
        case .action(let action):
            preparedAction = action
        case .terminal(let outcome):
            return outcome
        }

        let initialState = state, initialRevision = revision
        let proposedState: RouterState<R>
        do {
            proposedState = try makeProposedState(preparedAction, from: initialState, hostReplacement: hostReplacement)
        } catch let failure as RouterResourceLimitFailure {
            return reject(transitionID, reason: .resourceLimit(failure), context: context)
        } catch let failure as RouterHostValidationFailure {
            return reject(transitionID, reason: .hostContract(failure), context: context)
        } catch let error as RouterMutationError {
            return reject(
                transitionID,
                reason: .mutation(error),
                context: context,
                action: preparedAction
            )
        } catch {
            preconditionFailure("RouterReducer surfaced an undocumented error: \(error)")
        }

        // A pending typed show reserves its ID for its own request lineage.
        // Descriptor-only or restore requests cannot acquire its result waiter.
        if let id = pendingPresentationConflict(in: proposedState, requestRootID: requestRootID) {
            return reject(transitionID, reason: .mutation(.presentationIdentityConflict(id)),
                          context: context, action: preparedAction)
        }

        let selection: RouterTransientSelectionPreparation<R>?
        switch prepareTransientSelection(for: preparedAction, owner: presentationCompletionOwner) {
        case .none: selection = nil
        case .ready(let prepared): selection = prepared
        case .rejected(let reason):
            return reject(transitionID, reason: reason, context: context, action: preparedAction)
        }
        defer { selection?.clear() }
        let originalPrecondition = executionPrecondition
        let executionPrecondition: RouterRequestPrecondition<R>? = if let selectedPrecondition = selection?.precondition {
            { state in originalPrecondition?(state) ?? selectedPrecondition(state) }
        } else { originalPrecondition }
        if let reason = executionPrecondition?(state) {
            return reject(transitionID, reason: reason, context: context, action: preparedAction)
        }

        if proposedState == initialState && hostReplacement == nil && !lifetimeMutation.replacesOwnership
            && self.authorization == nil && authorization?.configuration == nil {
            return unchangedOutcome(
                id: transitionID,
                state: initialState,
                revision: initialRevision,
                action: preparedAction,
                context: context
            )
        }

        let transition = RouterTransition(
            id: transitionID,
            action: preparedAction,
            initialState: initialState,
            proposedState: proposedState,
            initialRevision: initialRevision,
            context: context
        )
        emit(.started(transition))

        if let rejection = await prepareAuthorization(
            for: transition, request: authorization, executionPrecondition: executionPrecondition
        ) {
            return reject(transitionID, reason: rejection, context: context, action: preparedAction)
        }

        let preparation = await prepare(
            for: transition,
            bypassesPolicies: bypassesPolicies,
            startingAt: startingPolicyIndex,
            requestSemantics: requestSemantics,
            authorization: authorization,
            lifetimeMutation: lifetimeMutation,
            hostReplacement: hostReplacement,
            requestRootID: requestRootID,
            presentationCompletionOwner: presentationCompletionOwner,
            executionPrecondition: executionPrecondition,
            deferredResumePreparation: deferredResumePreparation
        )
        return resolvePreparedTransition(
            preparation,
            transition: transition,
            requestRootID: requestRootID,
            presentationCompletionOwner: presentationCompletionOwner,
            lifetimeMutation: lifetimeMutation,
            hostReplacement: hostReplacement,
            executionPrecondition: executionPrecondition
        )
    }

    private func resolvePreparedTransition(
        _ preparation: RouterPolicyPreparation,
        transition: RouterTransition<R>,
        requestRootID: RouterTransitionID,
        presentationCompletionOwner: RouterPresentationCompletionOwner,
        lifetimeMutation: RouterScopeLifetimeMutation,
        hostReplacement: RouterHostReplacement<R>?,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) -> RouterOutcome<R> {
        switch preparation {
        case .allowed:
            return commitPreparedTransition(
                transition,
                requestRootID: requestRootID,
                presentationCompletionOwner: presentationCompletionOwner,
                lifetimeMutation: lifetimeMutation,
            hostReplacement: hostReplacement,
                executionPrecondition: executionPrecondition
            )
        case .rejected(let reason):
            return reject(
                transition.id,
                reason: reason,
                context: transition.context,
                action: transition.action
            )
        case .deferred(let deferral):
            emit(
                .deferred(
                    transitionID: transition.id,
                    state: state,
                    revision: revision,
                    deferral: deferral,
                    context: transition.context
                )
            )
            refreshScopes(after: transition.action, context: transition.context)
            return .deferred(
                id: transition.id,
                state: state,
                revision: revision,
                deferral: deferral
            )
        }
    }
}
