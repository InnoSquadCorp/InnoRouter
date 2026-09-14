// MARK: - RouterStore.swift
// InnoRouterSwiftUI - canonical InnoRouter 6 state authority
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation
import SwiftUI

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
    public private(set) var state: RouterState<R>

    /// Monotonic committed-state revision used for stale-prepare detection.
    public private(set) var revision: UInt64

    /// Payload-safe unresolved requests released by prepare policies.
    public package(set) var deferredTransitions: [RouterDeferredTransition] = []

    @ObservationIgnored
    let policies: [RouterPolicy<R>]
    @ObservationIgnored
    private let schedulingPolicy: RouterSchedulingPolicy
    @ObservationIgnored
    let maximumPendingRequestCount: Int
    @ObservationIgnored
    let requestOverflowStrategy: RouterRequestOverflowStrategy
    @ObservationIgnored
    let policyTimeout: Duration?
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
    var activePolicyRaces: [RouterTransitionID: RouterPolicyTimeoutRace] = [:]
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

    /// Opt-in stream of every request before scheduling or reduction.
    public var requestObservations: AsyncStream<RouterRequestObservation<R>> {
        requestBroadcaster.stream()
    }

    public init(
        initialState: RouterState<R>,
        configuration: RouterStoreConfiguration<R> = .init()
    ) {
        do {
            try initialState.validate()
        } catch {
            preconditionFailure("RouterStore requires a valid initial state: \(error)")
        }
        if let error = Self.sceneCatalogValidationError(in: initialState) {
            preconditionFailure("RouterStore requires scene-catalog-valid initial state: \(error)")
        }
        self.state = initialState
        self.revision = 0
        self.policies = configuration.policies
        self.schedulingPolicy = configuration.schedulingPolicy
        self.maximumPendingRequestCount = max(0, configuration.maximumPendingRequestCount)
        self.requestOverflowStrategy = configuration.requestOverflowStrategy
        self.policyTimeout = configuration.policyTimeout
        var deferrals = configuration.deferrals
        deferrals.maximumPendingCount = max(0, deferrals.maximumPendingCount)
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

    /// Creates a root-stack router and rejects an invalid initial state.
    public convenience init(
        initialPath: [R] = [],
        configuration: RouterStoreConfiguration<R> = .init()
    ) {
        // This construction is structurally valid by definition.
        let state = try! RouterState<R>(root: .stack(path: initialPath))
        self.init(initialState: state, configuration: configuration)
    }

    /// Returns the stable read-only projection for `path`.
    public func scope(at path: RouterScopePath = .root) -> RouterScope<R> {
        compactDeadScopes()
        if let scope = scopes[path]?.value, scope.matchesCurrentSceneLifetime {
            return scope
        }
        let scope = RouterScope(
            path: path,
            node: state.node(at: path),
            store: self
        )
        scopes[path] = WeakRouterScope(scope)
        return scope
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

    package func perform(
        _ action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        bypassesPolicies: Bool,
        startingPolicyIndex: Int = 0,
        transitionID: RouterTransitionID? = nil,
        requestRootID: RouterTransitionID? = nil,
        requestSemantics: RouterRequestSemantics<R> = .action,
        executionPrecondition: RouterRequestPrecondition<R>? = nil,
        executionPreparation: RouterRequestPreparationBuilder<R>? = nil,
        deferredResumePreparation: RouterDeferredResumePreparationBuilder<R>? = nil,
        systemRepairIdentity: RouterSystemRepairIdentity? = nil
    ) async -> RouterOutcome<R> {
        let transitionID = transitionID ?? runtimeDependencies.makeTransitionID()
        let requestRootID = requestRootID ?? transitionID
        observeRequest(
            id: transitionID,
            action: action,
            context: context,
            expectedRevision: expectedRevision,
            semantics: requestSemantics
        )

        return await withTaskCancellationHandler {
            if Task.isCancelled {
                observeCancellation(transitionID)
                return reject(
                    transitionID,
                    reason: .cancelled,
                    context: context,
                    action: action
                )
            }
            if let activeTransitionID {
                switch schedulingPolicy {
                case .rejectWhileBusy where !bypassesPolicies:
                    return reject(
                        transitionID,
                        reason: .busy(activeTransition: activeTransitionID),
                        context: context,
                        action: action
                    )
                case .rejectWhileBusy, .serialize:
                    return await withCheckedContinuation { continuation in
                        if requestCancellationIsPending(transitionID) {
                            cancelledRequestIDs.remove(transitionID)
                            continuation.resume(
                                returning: reject(
                                    transitionID,
                                    reason: .cancelled,
                                    context: context,
                                    action: action
                                )
                            )
                        } else {
                            enqueue(
                                QueuedRouterRequest(
                                    id: transitionID,
                                    rootID: requestRootID,
                                    action: action,
                                    context: context,
                                    semantics: requestSemantics,
                                    expectedRevision: expectedRevision,
                                    bypassesPolicies: bypassesPolicies,
                                    systemRepairIdentity: systemRepairIdentity,
                                    startingPolicyIndex: startingPolicyIndex,
                                    executionPrecondition: executionPrecondition,
                                    executionPreparation: executionPreparation,
                                    deferredResumePreparation: deferredResumePreparation,
                                    continuation: continuation
                                )
                            )
                        }
                    }
                }
            }

            activeTransitionID = transitionID
            activeRequestRootID = requestRootID
            activeRequestKey = context.requestKey
            activeSystemRepairIdentity = systemRepairIdentity
            return await execute(
                action,
                context: context,
                expectedRevision: expectedRevision,
                bypassesPolicies: bypassesPolicies,
                startingPolicyIndex: startingPolicyIndex,
                transitionID: transitionID,
                requestRootID: requestRootID,
                requestSemantics: requestSemantics,
                executionPrecondition: executionPrecondition,
                executionPreparation: executionPreparation,
                deferredResumePreparation: deferredResumePreparation
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(transitionID)
            }
        }
    }

    package func reserveTransitionID() -> RouterTransitionID {
        runtimeDependencies.makeTransitionID()
    }

    private func commitPreparedTransition(
        _ transition: RouterTransition<R>,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) -> RouterOutcome<R> {
        guard revision == transition.initialRevision else {
            return reject(
                transition.id,
                reason: .staleState(
                    expectedRevision: transition.initialRevision,
                    actualRevision: revision
                ),
                context: transition.context,
                action: transition.action
            )
        }
        guard !requestCancellationIsPending(transition.id) else {
            return reject(
                transition.id,
                reason: .cancelled,
                context: transition.context,
                action: transition.action
            )
        }
        if let rejection = executionPrecondition?(state) {
            return reject(
                transition.id,
                reason: rejection,
                context: transition.context,
                action: transition.action
            )
        }
        guard !requestCancellationIsPending(transition.id) else {
            return reject(
                transition.id,
                reason: .cancelled,
                context: transition.context,
                action: transition.action
            )
        }

        return commitOutcome(
            id: transition.id,
            before: transition.initialState,
            after: transition.proposedState,
            action: transition.action,
            context: transition.context
        )
    }

    private func makeProposedState(
        _ action: RouterAction<R>,
        from initialState: RouterState<R>
    ) throws -> RouterState<R> {
        let proposedState = try RouterReducer.reduce(action, from: initialState)
        if let error = Self.sceneCatalogValidationError(in: proposedState) {
            throw error
        }
        return proposedState
    }

    private func unchangedOutcome(
        id: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64,
        action: RouterAction<R>,
        context: RouterTransitionContext
    ) -> RouterOutcome<R> {
        emit(.unchanged(
            transitionID: id,
            state: state,
            revision: revision,
            context: context
        ))
        refreshScopes(after: action, context: context)
        return .unchanged(id: id, state: state, revision: revision)
    }

    private func commitOutcome(
        id: RouterTransitionID,
        before: RouterState<R>,
        after: RouterState<R>,
        action: RouterAction<R>,
        context: RouterTransitionContext
    ) -> RouterOutcome<R> {
        updateSceneLifecycleTokens(before: before, after: after)
        commit(after, animation: context.animation)
        revision &+= 1
        refreshScopes(after: action, context: context)
        finishDismissedPresentations(
            before: before,
            after: after,
            transitionID: id,
            context: context
        )
        emit(.committed(
            transitionID: id,
            before: before,
            after: after,
            revision: revision,
            context: context
        ))
        return .applied(id: id, before: before, after: after, revision: revision)
    }

    private func commit(
        _ proposedState: RouterState<R>,
        animation: RouterAnimation?
    ) {
        switch animation {
        case nil:
            state = proposedState
        case .some(.none):
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { state = proposedState }
        case .default:
            withAnimation { state = proposedState }
        case .easeInOut(let duration):
            withAnimation(.easeInOut(duration: max(0, duration))) {
                state = proposedState
            }
        case .spring(let duration, let bounce):
            withAnimation(
                .spring(
                    duration: max(0.01, duration),
                    bounce: min(max(0, bounce), 1)
                )
            ) {
                state = proposedState
            }
        }
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
            proposedState = try makeProposedState(preparedAction, from: initialState)
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

        if proposedState == initialState {
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

        let preparation = await prepare(
            for: transition,
            bypassesPolicies: bypassesPolicies,
            startingAt: startingPolicyIndex,
            requestSemantics: requestSemantics,
            requestRootID: requestRootID,
            executionPrecondition: executionPrecondition,
            deferredResumePreparation: deferredResumePreparation
        )
        switch preparation {
        case .allowed:
            return commitPreparedTransition(
                transition,
                executionPrecondition: executionPrecondition
            )
        case .rejected(let reason):
            return reject(
                transitionID,
                reason: reason,
                context: context,
                action: preparedAction
            )
        case .deferred(let deferral):
            emit(
                .deferred(
                    transitionID: transitionID,
                    state: state,
                    revision: revision,
                    deferral: deferral,
                    context: context
                )
            )
            refreshScopes(after: preparedAction, context: context)
            return .deferred(
                id: transitionID,
                state: state,
                revision: revision,
                deferral: deferral
            )
        }
    }
}
