// MARK: - RouterObservability.swift
// InnoRouterSystem - payload-safe diagnostics and metrics adapter
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import OSLog

import InnoRouterCore
import InnoRouterSwiftUI

/// Payload-free lifecycle classification for logging and application metrics.
public enum RouterDiagnosticEventKind: String, Sendable, Hashable, Codable {
    case started
    case policyAllowed
    case policyDeferred
    case policyRejected
    case committed
    case unchanged
    case deferred
    case platformAdapted
    case rejectedMutation
    case rejectedPolicy
    case rejectedBusy
    case rejectedCoalesced
    case rejectedSuperseded
    case rejectedQueueOverflow
    case rejectedPolicyTimeout
    case rejectedDeferral
    case rejectedStaleState
    case rejectedCancelled
    case rejectedMissingAuthority
}

/// A payload-safe diagnostic value derived from one typed router event.
public struct RouterDiagnosticEvent: Sendable, Hashable, Codable {
    public let kind: RouterDiagnosticEventKind
    public let transitionID: RouterTransitionID
    public let source: RouterTransitionSource?
    public let revision: UInt64?
    public let policy: String?

    public init(
        kind: RouterDiagnosticEventKind,
        transitionID: RouterTransitionID,
        source: RouterTransitionSource? = nil,
        revision: UInt64? = nil,
        policy: String? = nil
    ) {
        self.kind = kind
        self.transitionID = transitionID
        self.source = source
        self.revision = revision
        self.policy = policy
    }
}

/// Converts typed router events into payload-safe diagnostics.
///
/// The adapter is opt-in and performs no remote collection. Applications can
/// send ``RouterDiagnosticEvent`` values to their own metrics boundary or use
/// the unified-logging factory for local diagnosis.
public struct RouterObservability<R: Route>: Sendable {
    private let observe: @MainActor @Sendable (RouterEvent<R>) -> Void
    private let emit: @MainActor @Sendable (RouterDiagnosticEvent) -> Void

    public init(
        emit: @escaping @MainActor @Sendable (RouterDiagnosticEvent) -> Void
    ) {
        self.emit = emit
        self.observe = { event in emit(Self.describe(event)) }
    }

    @MainActor
    public func record(_ event: RouterEvent<R>) {
        observe(event)
    }

    /// Combines independent local logging and app-owned metrics adapters.
    public static func combined(_ adapters: [Self]) -> Self {
        Self { diagnostic in
            for adapter in adapters {
                adapter.emitDiagnostic(diagnostic)
            }
        }
    }

    /// Emits structural lifecycle diagnostics to Apple unified logging.
    public static func osLog(
        subsystem: String = "io.innosquad.innorouter",
        category: String = "router"
    ) -> Self {
        let logger = Logger(subsystem: subsystem, category: category)
        return Self { event in
            let kind = event.kind.rawValue
            let transitionID = event.transitionID.description
            let source = event.source?.rawValue ?? "none"
            let revision = event.revision.map(String.init) ?? "none"
            switch event.kind {
            case .committed:
                logger.info(
                    "Router \(kind, privacy: .public) id=\(transitionID, privacy: .public) source=\(source, privacy: .public) revision=\(revision, privacy: .public)"
                )
            case .rejectedMutation, .rejectedPolicy, .rejectedBusy,
                 .rejectedCoalesced, .rejectedSuperseded,
                 .rejectedQueueOverflow, .rejectedPolicyTimeout,
                 .rejectedDeferral,
                 .rejectedStaleState, .rejectedCancelled, .rejectedMissingAuthority,
                 .policyRejected:
                logger.error(
                    "Router \(kind, privacy: .public) id=\(transitionID, privacy: .public) source=\(source, privacy: .public) revision=\(revision, privacy: .public)"
                )
            case .started, .policyAllowed, .policyDeferred, .unchanged,
                 .deferred, .platformAdapted:
                logger.debug(
                    "Router \(kind, privacy: .public) id=\(transitionID, privacy: .public) source=\(source, privacy: .public) revision=\(revision, privacy: .public)"
                )
            }
        }
    }

    /// Emits payload-free transition intervals and lifecycle events for
    /// Instruments' Points of Interest track.
    ///
    /// A `started` event begins an interval. Committed, unchanged, deferred,
    /// and rejected outcomes close it; policy and platform events are emitted
    /// as points. Releasing the adapter closes any outstanding intervals.
    /// Route values and policy messages are never included.
    @MainActor
    public static func signposts(
        subsystem: String = "io.innosquad.innorouter",
        category: String = "router"
    ) -> Self {
        let signposter = OSSignposter(subsystem: subsystem, category: category)
        let tracker = RouterSignpostTracker(
            begin: {
                let id = signposter.makeSignpostID()
                return RouterSignpostInterval(
                    id: id,
                    state: signposter.beginInterval("Router Transition", id: id)
                )
            },
            end: { signposter.endInterval("Router Transition", $0.state) },
            point: { kind, interval in
                switch kind {
                case .outcome:
                    signposter.emitEvent("Router Outcome")
                case .lifecycle:
                    if let interval {
                        signposter.emitEvent("Router Lifecycle", id: interval.id)
                    } else {
                        signposter.emitEvent("Router Lifecycle")
                    }
                }
            }
        )
        return Self { event in
            tracker.record(event)
        }
    }

    @MainActor
    private func emitDiagnostic(_ diagnostic: RouterDiagnosticEvent) {
        emit(diagnostic)
    }

    private static func describe(_ event: RouterEvent<R>) -> RouterDiagnosticEvent {
        switch event {
        case .started(let transition):
            return .init(
                kind: .started,
                transitionID: transition.id,
                source: transition.context.source,
                revision: transition.initialRevision
            )
        case .policyPrepared(let id, let policy, let decision):
            let kind: RouterDiagnosticEventKind = switch decision {
            case .allow: .policyAllowed
            case .reject: .policyRejected
            case .deferRequest: .policyDeferred
            }
            return .init(
                kind: kind,
                transitionID: id,
                policy: policy
            )
        case .committed(let id, _, _, let revision, let context):
            return .init(
                kind: .committed,
                transitionID: id,
                source: context.source,
                revision: revision
            )
        case .unchanged(let id, _, let revision, let context):
            return .init(
                kind: .unchanged,
                transitionID: id,
                source: context.source,
                revision: revision
            )
        case .deferred(let id, _, let revision, _, let context):
            return .init(
                kind: .deferred,
                transitionID: id,
                source: context.source,
                revision: revision
            )
        case .rejected(let id, _, let revision, let reason, let context):
            return .init(
                kind: rejectionKind(reason),
                transitionID: id,
                source: context.source,
                revision: revision
            )
        case .platformAdapted(let id, _, let revision):
            return .init(
                kind: .platformAdapted,
                transitionID: id,
                revision: revision
            )
        }
    }

    private static func rejectionKind(
        _ reason: RouterRejectionReason
    ) -> RouterDiagnosticEventKind {
        switch reason {
        case .mutation, .featureProjection: .rejectedMutation
        case .policy: .rejectedPolicy
        case .busy: .rejectedBusy
        case .coalesced: .rejectedCoalesced
        case .superseded: .rejectedSuperseded
        case .queueOverflow: .rejectedQueueOverflow
        case .policyTimedOut: .rejectedPolicyTimeout
        case .deferralConflict, .deferralNotFound,
             .deferralCapacityExceeded, .deferralExpired, .deferralEvicted:
            .rejectedDeferral
        case .staleState: .rejectedStaleState
        case .cancelled: .rejectedCancelled
        case .missingAuthority: .rejectedMissingAuthority
        }
    }
}

private struct RouterSignpostInterval {
    let id: OSSignpostID
    let state: OSSignpostIntervalState
}

public extension RouterStoreConfiguration {
    /// Returns a copy that preserves the existing event callback and adds the
    /// supplied payload-safe observer.
    func observing(_ observability: RouterObservability<R>) -> Self {
        var copy = self
        let existing = onEvent
        copy.onEvent = { event in
            existing?(event)
            observability.record(event)
        }
        return copy
    }
}
