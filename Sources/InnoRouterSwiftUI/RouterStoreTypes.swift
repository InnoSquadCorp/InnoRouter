import Foundation

import InnoRouterCore

/// Terminal value returned to the caller that awaited a route presentation.
public enum RouterPresentationOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case dismissed
    case cancelled
    case rejected(RouterRejectionReason)
}

extension RouterPresentationOutcome: Equatable where Value: Equatable {}

/// A destination could not complete the currently presented route.
public enum RouterPresentationCompletionError: Error, Hashable, Sendable {
    case noActivePresentation(scope: RouterScopePath)
    case presentationWasNotAwaited(UUID)
    case resultTypeMismatch(UUID)
    case completionAlreadyPending(UUID)
    case presentationRouteMismatch(UUID)
    case dismissalRejected(RouterRejectionReason)
    case dismissalDeferred(RouterDeferralID)
}

enum RouterPresentationCompletionOwner: Hashable, Sendable {
    case transition(RouterTransitionID)
    case deferral(RouterDeferralID, incarnation: UUID)
}

enum RouterPresentationValuePreparation {
    case prepared
    case typeMismatch
    case alreadyPending
}

/// Snapshot provenance plus the normal transition outcome produced when it is
/// applied to a store.
public struct RouterRestorationOutcome<R: Route>: Hashable, Sendable {
    public let decoding: RouterSnapshotDecodingResult<R>
    public let transition: RouterOutcome<R>

    public init(
        decoding: RouterSnapshotDecodingResult<R>,
        transition: RouterOutcome<R>
    ) {
        self.decoding = decoding
        self.transition = transition
    }
}

@MainActor
final class RouterPresentationWaiter<Value: Sendable> {
    var activatedPresentationToken: UUID?
    private var terminal: RouterPresentationOutcome<Value>?
    private var continuation: CheckedContinuation<RouterPresentationOutcome<Value>, Never>?
    private var pendingValue: (owner: RouterPresentationCompletionOwner, value: Value, actionID: RouterPresentationActionID?)?

    func wait() async -> RouterPresentationOutcome<Value> {
        if let terminal {
            return terminal
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func prepare(
        _ value: Value,
        owner: RouterPresentationCompletionOwner,
        actionID: RouterPresentationActionID? = nil
    ) -> RouterPresentationValuePreparation {
        guard terminal == nil else { return .alreadyPending }
        if let pendingValue {
            return actionID != nil && pendingValue.owner == owner && pendingValue.actionID == actionID
                ? .prepared : .alreadyPending
        }
        pendingValue = (owner, value, actionID)
        return .prepared
    }

    func movePreparedValue(
        from currentOwner: RouterPresentationCompletionOwner,
        to nextOwner: RouterPresentationCompletionOwner
    ) {
        guard let pendingValue, pendingValue.owner == currentOwner else { return }
        self.pendingValue = (nextOwner, pendingValue.value, pendingValue.actionID)
    }

    func clearPreparedValue(ownedBy owner: RouterPresentationCompletionOwner) {
        guard pendingValue?.owner == owner else { return }
        pendingValue = nil
    }

    func finishAfterDismissal(ownedBy owner: RouterPresentationCompletionOwner) {
        if let pendingValue, pendingValue.owner == owner {
            finish(.value(pendingValue.value))
        } else {
            finish(.dismissed)
        }
    }

    func finish(_ outcome: RouterPresentationOutcome<Value>) {
        guard terminal == nil else { return }
        terminal = outcome
        continuation?.resume(returning: outcome)
        continuation = nil
        pendingValue = nil
    }
}

@MainActor
struct AnyRouterPresentationWaiter {
    let identity = UUID()
    let ownerPath: RouterScopePath
    let showRequestRootID: RouterTransitionID
    let activatedToken: () -> UUID?
    let activate: (UUID) -> Void
    let prepareValue: (Any, RouterPresentationCompletionOwner) -> RouterPresentationValuePreparation
    let prepareAction: ((RouterPresentationActionID, RouterPresentationCompletionOwner) -> RouterPresentationValuePreparation)?
    let resultPrecondition: @MainActor @Sendable () -> RouterRejectionReason?
    let movePreparedValue: (
        RouterPresentationCompletionOwner,
        RouterPresentationCompletionOwner
    ) -> Void
    let clearPreparedValue: (RouterPresentationCompletionOwner) -> Void
    let finishAfterDismissal: (RouterPresentationCompletionOwner) -> Void
    let finishCancelled: () -> Void
    let finishRejected: (RouterRejectionReason) -> Void
    let lifetimeIsCurrent: () -> Bool
}

/// One synchronous or suspending admission policy in the router prepare phase.
public struct RouterPolicy<R: Route>: Sendable {
    public let name: String
    private let operation: @MainActor @Sendable (RouterTransition<R>) async -> RouterPolicyDecision

    public init(
        name: String,
        prepare: @escaping @MainActor @Sendable (RouterTransition<R>) async -> RouterPolicyDecision
    ) {
        self.name = name
        self.operation = prepare
    }

    @MainActor
    func prepare(_ transition: RouterTransition<R>) async -> RouterPolicyDecision {
        await operation(transition)
    }
}

/// Configuration captured when a ``RouterStore`` is created.
public enum RouterSchedulingPolicy: Sendable {
    /// Preserve request order and execute one policy pipeline at a time.
    case serialize
    /// Reject requests that arrive while another policy pipeline is active.
    case rejectWhileBusy
}

/// When a fire-and-forget request made through ``RouterActions`` commits.
///
/// `RouterActions` methods such as `go(_:)`, `back()`, `sheet(_:)`,
/// `apply(_:)`, and `transaction(_:)` return a task instead of suspending the
/// caller. This setting decides whether the transition they request is
/// committed before they return.
///
/// It applies to ``RouterActions`` only, which is what views reach through
/// `@EnvironmentRouter`. ``RouterStore/dispatch(_:context:)``,
/// ``RouterScope/dispatch(_:context:)``, ``RouterScope/dispatchRoot(_:context:)``,
/// and the hosts' native bindings (navigation path, tab selection, sheet
/// dismissal) always commit on a later turn.
///
/// The value set is a struct with static members, not an enum, so a later
/// minor release can add a timing without breaking an exhaustive `switch`.
public struct RouterDispatchTiming: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case deferred
        case immediateWhenIdle
    }

    let kind: Kind

    /// Commit on a later main-actor turn. This is the 7.0 behavior and the
    /// default: the caller never observes the new state before it returns.
    public static let deferred = RouterDispatchTiming(kind: .deferred)

    /// Commit before the call returns whenever nothing requires waiting, so a
    /// surrounding `withAnimation` or `withTransaction` applies to the
    /// navigation change.
    ///
    /// A request commits immediately only when all of these hold:
    ///
    /// - the Store has no prepare policy and no authorization;
    /// - no other request is in flight, queued, or still on its way from an
    ///   earlier fire-and-forget call made through this library;
    /// - the call is not made from inside a `RouterEvent` or request
    ///   observer callback;
    /// - the calling task is not cancelled.
    ///
    /// Otherwise it takes the deferred path, so call order and every policy
    /// guarantee are unchanged. Three kinds of request always take the
    /// deferred path: one made through a feature projection, and `dismiss()`
    /// or `setPresentationDetent(_:)` called from inside presented content.
    ///
    /// The Store cannot see a request that your own code starts in a `Task`
    /// (for example `Task { await router.perform(...) }`), so an immediate
    /// request made later in the same turn commits before it.
    ///
    /// An immediate commit also delivers its `RouterEvent`s, `onEvent`
    /// included, before the call returns, inside the caller's transaction.
    /// Call from a user-interaction handler such as a button action, not
    /// while a view body is being evaluated: the commit mutates observable
    /// state synchronously.
    public static let immediateWhenIdle = RouterDispatchTiming(kind: .immediateWhenIdle)
}

/// What must be true, besides an idle lane, for a request to commit
/// synchronously. Each field closes a way an immediate commit could run out
/// of the order in which requests were made.
struct RouterDispatchGate {
    /// Fire-and-forget requests whose task has not started. They are in
    /// neither the lane nor a queue yet, so only this count keeps a later
    /// immediate request from overtaking them.
    var unstartedDispatches = 0
    /// Depth of event and request-observer callbacks in progress. A request
    /// made from inside one must not commit, and publish its own events,
    /// before the event being delivered has reached every observer.
    var notificationDepth = 0
    /// Set while a request commits synchronously. That request runs on the
    /// caller's task, whose cancellation is not the request's: the deferred
    /// path would have run it on a task of its own.
    var ignoresTaskCancellation = false

    var isOpen: Bool { unstartedDispatches == 0 && notificationDepth == 0 }
}

/// Bounds unresolved policy deferrals and optionally expires them.
public struct RouterDeferralConfiguration: Sendable {
    public var maximumPendingCount: Int
    public var timeToLive: Duration?
    public var overflowStrategy: RouterDeferralOverflowStrategy

    public init(
        maximumPendingCount: Int = 64,
        timeToLive: Duration? = .seconds(15 * 60),
        overflowStrategy: RouterDeferralOverflowStrategy = .rejectNewest
    ) {
        self.maximumPendingCount = maximumPendingCount
        self.timeToLive = timeToLive
        self.overflowStrategy = overflowStrategy
    }
}

/// Configuration captured when a ``RouterStore`` is created.
public struct RouterStoreConfiguration<R: Route>: Sendable {
    private var baseResourceBudget: RouterResourceBudget
    /// Shared structural and execution limits. Replacing the budget also updates
    /// legacy execution fields; editing those fields is reflected in this value.
    /// Existing overflow strategies are retained when limits are replaced.
    public var resourceBudget: RouterResourceBudget {
        get {
            baseResourceBudget.replacingStoreLimits(
                maximumPendingRequests: maximumPendingRequestCount,
                maximumDeferrals: deferrals.maximumPendingCount,
                maximumActivePolicyOperations: maximumActivePolicyOperationCount,
                maximumActiveRestorationOperations: maximumActiveRestorationOperationCount,
                policyTimeout: policyTimeout,
                deferralLifetime: deferrals.timeToLive
            )
        }
        set {
            baseResourceBudget = newValue
            maximumPendingRequestCount = newValue.maximumPendingRequests
            deferrals.maximumPendingCount = newValue.maximumDeferrals
            maximumActivePolicyOperationCount = newValue.maximumActivePolicyOperations
            maximumActiveRestorationOperationCount = newValue.maximumActiveRestorationOperations
            policyTimeout = newValue.policyTimeout
            deferrals.timeToLive = newValue.deferralLifetime
        }
    }

    /// Frozen renderer contract. Native hosts require an explicit compatible descriptor.
    public var hostDescriptor: RouterHostDescriptor<R>?

    public var policies: [RouterPolicy<R>]
    /// Optional authoritative app authorization for every Store application.
    public var authorization: RouterAuthorizationConfiguration<R>?
    public var schedulingPolicy: RouterSchedulingPolicy
    /// When fire-and-forget ``RouterActions`` requests commit. Defaults to
    /// ``RouterDispatchTiming/deferred``. The Store's and scopes' own
    /// `dispatch` methods are not affected; see ``RouterDispatchTiming``.
    public var dispatchTiming: RouterDispatchTiming
    public var maximumPendingRequestCount: Int
    public var requestOverflowStrategy: RouterRequestOverflowStrategy
    /// Deadline for each asynchronous policy or authorization decision. Waiting
    /// for login UI is a separate pending intent and does not occupy this timer.
    public var policyTimeout: Duration?
    /// Shared maximum of policy and authorization operations that may remain alive, including operations
    /// whose requests timed out or were cancelled. Zero prevents policy work;
    /// negative values are rejected by Store initialization. `nil` explicitly opts out of the bound.
    ///
    /// The default of 64 is provisional and uncalibrated for the 7.0 development
    /// cycle. Workload and memory calibration is a required release gate.
    /// Cancellation is cooperative; synchronous MainActor work cannot be
    /// preempted by this limit or a timeout.
    public var maximumActivePolicyOperationCount: Int?
    /// Maximum partial-restoration planners that may remain alive for this
    /// Store, shared with history validation. One operation includes the whole
    /// sequential validation/fallback plan, even after timeout or cancellation.
    /// Its slot is returned only when application work actually terminates.
    /// This is a separate budget from policy/authorization operations.
    ///
    /// Zero prevents planning; negative values are rejected by Store initialization. `nil`
    /// explicitly opts out. The default of 8 is provisional and uncalibrated
    /// for 7.0; workload and memory calibration remains a release gate.
    /// Cancellation is cooperative. Neither this bound nor a timeout can
    /// preempt synchronous MainActor application work.
    public var maximumActiveRestorationOperationCount: Int?
    public var deferrals: RouterDeferralConfiguration
    public var eventBufferingPolicy: EventBufferingPolicy
    public var onEvent: (@MainActor @Sendable (RouterEvent<R>) -> Void)?
    package var runtimeDependencies: RouterRuntimeDependencies

    public init(
        hostDescriptor: RouterHostDescriptor<R>? = nil,
        policies: [RouterPolicy<R>] = [],
        authorization: RouterAuthorizationConfiguration<R>? = nil,
        schedulingPolicy: RouterSchedulingPolicy = .serialize,
        dispatchTiming: RouterDispatchTiming = .deferred,
        maximumPendingRequestCount: Int = 256,
        requestOverflowStrategy: RouterRequestOverflowStrategy = .rejectNewest,
        policyTimeout: Duration? = .seconds(30),
        maximumActivePolicyOperationCount: Int? = 64,
        maximumActiveRestorationOperationCount: Int? = 8,
        deferrals: RouterDeferralConfiguration = .init(),
        eventBufferingPolicy: EventBufferingPolicy = .default,
        onEvent: (@MainActor @Sendable (RouterEvent<R>) -> Void)? = nil
    ) {
        self.hostDescriptor = hostDescriptor
        self.baseResourceBudget = .provisional
        self.policies = policies
        self.authorization = authorization
        self.schedulingPolicy = schedulingPolicy
        self.dispatchTiming = dispatchTiming
        self.maximumPendingRequestCount = maximumPendingRequestCount
        self.requestOverflowStrategy = requestOverflowStrategy
        self.policyTimeout = policyTimeout
        self.maximumActivePolicyOperationCount = maximumActivePolicyOperationCount
        self.maximumActiveRestorationOperationCount = maximumActiveRestorationOperationCount
        self.deferrals = deferrals
        self.eventBufferingPolicy = eventBufferingPolicy
        self.onEvent = onEvent
        self.runtimeDependencies = .live
    }

    /// Configures every shared limit from one explicit budget. Individual
    /// execution fields remain mutable compatibility aliases afterward.
    public init(
        resourceBudget: RouterResourceBudget,
        hostDescriptor: RouterHostDescriptor<R>? = nil,
        policies: [RouterPolicy<R>] = [],
        authorization: RouterAuthorizationConfiguration<R>? = nil,
        schedulingPolicy: RouterSchedulingPolicy = .serialize,
        dispatchTiming: RouterDispatchTiming = .deferred,
        requestOverflowStrategy: RouterRequestOverflowStrategy = .rejectNewest,
        deferralOverflowStrategy: RouterDeferralOverflowStrategy = .rejectNewest,
        eventBufferingPolicy: EventBufferingPolicy = .default,
        onEvent: (@MainActor @Sendable (RouterEvent<R>) -> Void)? = nil
    ) {
        self.init(
            hostDescriptor: hostDescriptor,
            policies: policies,
            authorization: authorization,
            schedulingPolicy: schedulingPolicy,
            dispatchTiming: dispatchTiming,
            requestOverflowStrategy: requestOverflowStrategy,
            deferrals: .init(overflowStrategy: deferralOverflowStrategy),
            eventBufferingPolicy: eventBufferingPolicy,
            onEvent: onEvent
        )
        self.resourceBudget = resourceBudget
    }
}

package enum RouterSystemRepairIdentity: Hashable, Sendable {
    case window(id: UUID, lifecycleToken: UUID)
    case immersiveSpace(id: String, lifecycleToken: UUID)
    case immersiveSpaceRecovery(RouterImmersiveActivation)
}

@MainActor
struct QueuedRouterRequest<R: Route> {
    let id: RouterTransitionID
    let rootID: RouterTransitionID
    let action: RouterAction<R>
    let context: RouterTransitionContext
    let presentationCompletionOwner: RouterPresentationCompletionOwner
    let semantics: RouterRequestSemantics<R>
    let replayLimitationCode: String?
    let authorization: RouterRequestAuthorization<R>?
    let lifetimeMutation: RouterScopeLifetimeMutation
    let hostReplacement: RouterHostReplacement<R>?
    let expectedRevision: UInt64?
    let bypassesPolicies: Bool
    /// Non-nil only for Store-owned native-scene reconciliation.
    let systemRepairIdentity: RouterSystemRepairIdentity?
    let startingPolicyIndex: Int
    let executionPrecondition: RouterRequestPrecondition<R>?
    let executionPreparation: RouterRequestPreparationBuilder<R>?
    let deferredResumePreparation: RouterDeferredResumePreparationBuilder<R>?
    let continuation: CheckedContinuation<RouterOutcome<R>, Never>
}

@MainActor
struct DeferredRouterRequest<R: Route> {
    let rootID: RouterTransitionID
    let action: RouterAction<R>
    let context: RouterTransitionContext
    let presentationCompletionOwner: RouterPresentationCompletionOwner
    let semantics: RouterRequestSemantics<R>
    let replayLimitationCode: String?
    let authorization: RouterRequestAuthorization<R>?
    let lifetimeMutation: RouterScopeLifetimeMutation
    let hostReplacement: RouterHostReplacement<R>?
    let initialRevision: UInt64
    let nextPolicyIndex: Int
    let executionPrecondition: RouterRequestPrecondition<R>?
    let resumePreparation: RouterDeferredResumePreparationBuilder<R>?
    let metadata: RouterDeferredTransition
}

struct RouterDeferralExpiration {
    let token: UUID
    let task: Task<Void, Never>
}
