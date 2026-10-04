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
    case deferral(RouterDeferralID)
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
    private var terminal: RouterPresentationOutcome<Value>?
    private var continuation: CheckedContinuation<RouterPresentationOutcome<Value>, Never>?
    private var pendingValue: (owner: RouterPresentationCompletionOwner, value: Value)?

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
        owner: RouterPresentationCompletionOwner
    ) -> RouterPresentationValuePreparation {
        guard pendingValue == nil else { return .alreadyPending }
        pendingValue = (owner, value)
        return .prepared
    }

    func movePreparedValue(
        from currentOwner: RouterPresentationCompletionOwner,
        to nextOwner: RouterPresentationCompletionOwner
    ) {
        guard let pendingValue, pendingValue.owner == currentOwner else { return }
        self.pendingValue = (nextOwner, pendingValue.value)
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
    let prepareValue: (Any, RouterPresentationCompletionOwner) -> RouterPresentationValuePreparation
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

/// Bounds unresolved policy deferrals and optionally expires them.
public struct RouterDeferralConfiguration: Sendable {
    public var maximumPendingCount: Int
    public var timeToLive: Duration?
    public var overflowStrategy: RouterDeferralOverflowStrategy

    public init(
        maximumPendingCount: Int = 64,
        timeToLive: Duration? = nil,
        overflowStrategy: RouterDeferralOverflowStrategy = .rejectNewest
    ) {
        self.maximumPendingCount = maximumPendingCount
        self.timeToLive = timeToLive
        self.overflowStrategy = overflowStrategy
    }
}

/// Configuration captured when a ``RouterStore`` is created.
public struct RouterStoreConfiguration<R: Route>: Sendable {
    public var policies: [RouterPolicy<R>]
    /// Optional authoritative app authorization for every Store application.
    public var authorization: RouterAuthorizationConfiguration<R>?
    public var schedulingPolicy: RouterSchedulingPolicy
    public var maximumPendingRequestCount: Int
    public var requestOverflowStrategy: RouterRequestOverflowStrategy
    /// Deadline for each asynchronous policy or authorization decision. Waiting
    /// for login UI is a separate pending intent and does not occupy this timer.
    public var policyTimeout: Duration?
    /// Shared maximum of policy and authorization operations that may remain alive, including operations
    /// whose requests timed out or were cancelled. Zero prevents policy work;
    /// negative values normalize to zero. `nil` explicitly opts out of the bound.
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
    /// Zero prevents planning; negative values normalize to zero. `nil`
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
        policies: [RouterPolicy<R>] = [],
        authorization: RouterAuthorizationConfiguration<R>? = nil,
        schedulingPolicy: RouterSchedulingPolicy = .serialize,
        maximumPendingRequestCount: Int = 256,
        requestOverflowStrategy: RouterRequestOverflowStrategy = .rejectNewest,
        policyTimeout: Duration? = nil,
        maximumActivePolicyOperationCount: Int? = 64,
        maximumActiveRestorationOperationCount: Int? = 8,
        deferrals: RouterDeferralConfiguration = .init(),
        eventBufferingPolicy: EventBufferingPolicy = .default,
        onEvent: (@MainActor @Sendable (RouterEvent<R>) -> Void)? = nil
    ) {
        self.policies = policies
        self.authorization = authorization
        self.schedulingPolicy = schedulingPolicy
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
}

package enum RouterSystemRepairIdentity: Hashable, Sendable {
    case window(id: UUID, lifecycleToken: UUID)
    case immersiveSpace(id: String, lifecycleToken: UUID)
}

@MainActor
struct QueuedRouterRequest<R: Route> {
    let id: RouterTransitionID
    let rootID: RouterTransitionID
    let action: RouterAction<R>
    let context: RouterTransitionContext
    let semantics: RouterRequestSemantics<R>
    let authorization: RouterRequestAuthorization<R>?
    let lifetimeMutation: RouterScopeLifetimeMutation
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
    let semantics: RouterRequestSemantics<R>
    let authorization: RouterRequestAuthorization<R>?
    let lifetimeMutation: RouterScopeLifetimeMutation
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
