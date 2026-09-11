// MARK: - RouterTransition.swift
// InnoRouterCore - typed transition identities, outcomes, and events
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

/// Semantic animation applied when a router transition commits.
public enum RouterAnimation: Hashable, Sendable, Codable {
    case `default`
    case easeInOut(duration: Double)
    case spring(duration: Double, bounce: Double)
    case none
}

/// Origin metadata available to policies, inspection, and diagnostics.
public enum RouterTransitionSource: String, Hashable, Sendable, Codable {
    case application
    case system
    case deepLink
    case restoration
    case appIntent
    case handoff
    case inspector
    case history
}

/// App-defined semantic identity used to collapse redundant pending requests.
public struct RouterRequestKey: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// Stable identity for a policy-deferred navigation request.
public struct RouterDeferralID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible {
    public var rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }

    public var description: String { rawValue.uuidString }
}

/// Queue behavior for requests that share one ``RouterRequestKey``.
public enum RouterRequestCoalescingStrategy: String, Hashable, Sendable, Codable {
    /// Preserve every request in FIFO order.
    case enqueue
    /// Keep the active or first pending request and reject later duplicates.
    case keepFirst
    /// Keep an active request, but replace an older pending duplicate with the latest request.
    case replacePending
}

/// Behavior when the serialized request queue reaches its configured bound.
public enum RouterRequestOverflowStrategy: String, Hashable, Sendable, Codable {
    /// Reject the arriving request and preserve every older pending request.
    case rejectNewest
    /// Reject the oldest pending request and append the arriving request.
    case discardOldest
}

/// Behavior when the unresolved policy-deferral registry reaches its bound.
public enum RouterDeferralOverflowStrategy: String, Hashable, Sendable, Codable {
    /// Reject the transition that attempted to create another deferral.
    case rejectNewest
    /// Cancel the oldest unresolved deferral and retain the new one.
    case cancelOldest
}

/// Non-navigation metadata carried alongside one action.
public struct RouterTransitionContext: Hashable, Sendable, Codable {
    public var source: RouterTransitionSource
    public var animation: RouterAnimation?
    public var requestKey: RouterRequestKey?
    public var coalescing: RouterRequestCoalescingStrategy
    public var resumedDeferral: RouterDeferralID?

    public init(
        source: RouterTransitionSource = .application,
        animation: RouterAnimation? = nil,
        requestKey: RouterRequestKey? = nil,
        coalescing: RouterRequestCoalescingStrategy = .enqueue,
        resumedDeferral: RouterDeferralID? = nil
    ) {
        self.source = source
        self.animation = animation
        self.requestKey = requestKey
        self.coalescing = coalescing
        self.resumedDeferral = resumedDeferral
    }
}

/// Correlates one router request across policy, commit, inspection, and tests.
public struct RouterTransitionID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible {
    public var rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }

    public var description: String { rawValue.uuidString }
}

/// Immutable input supplied to every prepare policy.
public struct RouterTransition<R: Route>: Hashable, Sendable {
    public var id: RouterTransitionID
    public var action: RouterAction<R>
    public var initialState: RouterState<R>
    public var proposedState: RouterState<R>
    public var initialRevision: UInt64
    public var context: RouterTransitionContext

    public init(
        id: RouterTransitionID,
        action: RouterAction<R>,
        initialState: RouterState<R>,
        proposedState: RouterState<R>,
        initialRevision: UInt64,
        context: RouterTransitionContext = .init()
    ) {
        self.id = id
        self.action = action
        self.initialState = initialState
        self.proposedState = proposedState
        self.initialRevision = initialRevision
        self.context = context
    }
}

/// One submitted request observed before queueing, reduction, or rejection.
///
/// This separate stream lets opt-in tooling capture unchanged and malformed
/// requests without adding diagnostic traffic to the ordinary event stream.
package enum RouterSceneRequestLifetime: Hashable, Sendable {
    case window(id: UUID, token: UUID)
    case immersiveSpace(id: String, token: UUID)
    case missingWindow(id: UUID)
    case missingImmersiveSpace(id: String)
}

package enum RouterRequestSemantics<R: Route>: Hashable, Sendable {
    case action
    case historyNavigation(RouterState<R>)
    case featureAction(
        scope: RouterScopePath,
        lifetime: RouterSceneRequestLifetime?,
        features: [RouterFeatureCatalogEntry]
    )
    case featurePlan(
        scope: RouterScopePath,
        lifetime: RouterSceneRequestLifetime?,
        node: RouterNode<R>,
        features: [RouterFeatureCatalogEntry]
    )
}

public struct RouterRequestObservation<R: Route>: Hashable, Sendable {
    public let id: RouterTransitionID
    public let action: RouterAction<R>
    public let context: RouterTransitionContext
    /// State revision that must still be current when this request executes.
    public let expectedRevision: UInt64?
    package let semantics: RouterRequestSemantics<R>

    public init(
        id: RouterTransitionID,
        action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64? = nil
    ) {
        self.id = id
        self.action = action
        self.context = context
        self.expectedRevision = expectedRevision
        self.semantics = .action
    }

    package init(
        id: RouterTransitionID,
        action: RouterAction<R>,
        context: RouterTransitionContext,
        expectedRevision: UInt64?,
        semantics: RouterRequestSemantics<R>
    ) {
        self.id = id
        self.action = action
        self.context = context
        self.expectedRevision = expectedRevision
        self.semantics = semantics
    }
}

/// A prepare policy's decision for a proposed transition.
public enum RouterPolicyDecision: Hashable, Sendable {
    case allow
    case reject(String)
    /// Release the execution lane and await an explicit app decision.
    case deferRequest(RouterDeferralID)
}

/// App decision supplied when resolving a deferred policy request.
public enum RouterDeferralResolution: Hashable, Sendable, Codable {
    case allow
    case reject(String)
    case cancel
}

/// Determines whether a deferred action may apply after router state changes.
public enum RouterDeferralResumeStrategy: Hashable, Sendable, Codable {
    case requireUnchangedState
    case rebaseOnCurrentState
}

/// Payload-safe metadata for one unresolved deferred transition.
public struct RouterDeferredTransition: Hashable, Sendable {
    public let id: RouterDeferralID
    public let transitionID: RouterTransitionID
    public let policy: String
    public let initialRevision: UInt64
    public let source: RouterTransitionSource
    public let createdAt: Date
    public let expiresAt: Date?

    public init(
        id: RouterDeferralID,
        transitionID: RouterTransitionID,
        policy: String,
        initialRevision: UInt64,
        source: RouterTransitionSource,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.transitionID = transitionID
        self.policy = policy
        self.initialRevision = initialRevision
        self.source = source
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// Typed terminal rejection from the canonical router pipeline.
public enum RouterRejectionReason: Hashable, Sendable {
    case mutation(RouterMutationError)
    case featureProjection(RouterFeatureProjectionError)
    case policy(name: String, message: String)
    case busy(activeTransition: RouterTransitionID)
    case coalesced(existingTransition: RouterTransitionID)
    case superseded(replacementTransition: RouterTransitionID)
    case queueOverflow(limit: Int)
    case policyTimedOut(name: String)
    case deferralConflict(RouterDeferralID)
    case deferralNotFound(RouterDeferralID)
    case deferralCapacityExceeded(limit: Int)
    case deferralExpired(RouterDeferralID)
    case deferralEvicted(RouterDeferralID)
    case staleState(expectedRevision: UInt64, actualRevision: UInt64)
    case cancelled
    case missingAuthority(routeType: String)
}

/// The terminal result returned exactly once for a router request.
public enum RouterOutcome<R: Route>: Hashable, Sendable {
    case applied(
        id: RouterTransitionID,
        before: RouterState<R>,
        after: RouterState<R>,
        revision: UInt64
    )
    case unchanged(
        id: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64
    )
    case deferred(
        id: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64,
        deferral: RouterDeferredTransition
    )
    case rejected(
        id: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64,
        reason: RouterRejectionReason
    )

    /// Correlation identifier shared with ``RouterEvent``.
    public var id: RouterTransitionID {
        switch self {
        case .applied(let id, _, _, _),
             .unchanged(let id, _, _),
             .deferred(let id, _, _, _),
             .rejected(let id, _, _, _):
            return id
        }
    }
}

/// Ordered observation events emitted by ``RouterStore``.
public enum RouterEvent<R: Route>: Hashable, Sendable {
    case started(RouterTransition<R>)
    case policyPrepared(
        transitionID: RouterTransitionID,
        policy: String,
        decision: RouterPolicyDecision
    )
    case committed(
        transitionID: RouterTransitionID,
        before: RouterState<R>,
        after: RouterState<R>,
        revision: UInt64,
        context: RouterTransitionContext
    )
    case unchanged(
        transitionID: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64,
        context: RouterTransitionContext
    )
    case deferred(
        transitionID: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64,
        deferral: RouterDeferredTransition,
        context: RouterTransitionContext
    )
    case rejected(
        transitionID: RouterTransitionID,
        state: RouterState<R>,
        revision: UInt64,
        reason: RouterRejectionReason,
        context: RouterTransitionContext
    )
    case platformAdapted(
        eventID: RouterTransitionID,
        adaptation: RouterPlatformAdaptation,
        revision: UInt64
    )
}
