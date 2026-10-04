// MARK: - RouterObservability.swift
// InnoRouterSystem - payload-safe diagnostics and metrics adapter
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation

import InnoRouterCore
import InnoRouterSwiftUI

/// Extensible lifecycle code. Existing wire strings are unchanged and unknown
/// future values are preserved; clients must keep a fallback in code switches.
public struct RouterDiagnosticEventKind: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let started = Self(rawValue: "started")
    public static let policyAllowed = Self(rawValue: "policyAllowed")
    public static let policyDeferred = Self(rawValue: "policyDeferred")
    public static let policyRejected = Self(rawValue: "policyRejected")
    public static let committed = Self(rawValue: "committed")
    public static let unchanged = Self(rawValue: "unchanged")
    public static let deferred = Self(rawValue: "deferred")
    public static let platformAdapted = Self(rawValue: "platformAdapted")
    public static let rejectedMutation = Self(rawValue: "rejectedMutation")
    public static let rejectedPolicy = Self(rawValue: "rejectedPolicy")
    public static let rejectedBusy = Self(rawValue: "rejectedBusy")
    public static let rejectedCoalesced = Self(rawValue: "rejectedCoalesced")
    public static let rejectedSuperseded = Self(rawValue: "rejectedSuperseded")
    public static let rejectedQueueOverflow = Self(rawValue: "rejectedQueueOverflow")
    public static let rejectedPolicyTimeout = Self(rawValue: "rejectedPolicyTimeout")
    public static let rejectedDeferral = Self(rawValue: "rejectedDeferral")
    public static let rejectedStaleState = Self(rawValue: "rejectedStaleState")
    public static let rejectedCancelled = Self(rawValue: "rejectedCancelled")
    public static let rejectedMissingAuthority = Self(rawValue: "rejectedMissingAuthority")
    public static let rejectedResourceLimit = Self(rawValue: "rejectedResourceLimit")
    public static let rejectedPendingLinkLifetime = Self(rawValue: "rejectedPendingLinkLifetime")
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
        case .policy, .policyCapacityExceeded, .authorization: .rejectedPolicy
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
        case .pendingLinkLifetime: .rejectedPendingLinkLifetime
        case .resourceLimit: .rejectedResourceLimit
        }
    }
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
