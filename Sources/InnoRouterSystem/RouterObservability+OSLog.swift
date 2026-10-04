// MARK: - RouterObservability+OSLog.swift
// InnoRouterSystem - Apple unified logging and Instruments adapters
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import OSLog

extension RouterObservability {
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
            default:
                logger.debug("Router unknown diagnostic id=\(transitionID, privacy: .public)")
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
}

private struct RouterSignpostInterval {
    let id: OSSignpostID
    let state: OSSignpostIntervalState
}
