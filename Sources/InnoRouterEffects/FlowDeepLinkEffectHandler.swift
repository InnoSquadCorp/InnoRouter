// MARK: - FlowDeepLinkEffectHandler.swift
// InnoRouterEffects - composite URL → FlowStore.apply bridge
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import InnoRouterCore
import InnoRouterDeepLink

/// Bridges ``FlowDeepLinkPipeline`` output into a ``FlowPlanApplier``
/// (typically a `FlowStore`) so a single URL rehydrates a push +
/// modal flow atomically.
///
/// Parallels ``DeepLinkEffectHandler`` for push-only pipelines —
/// push-only callers keep their existing handler untouched, and
/// FlowStore-driven callers opt into this type for composite
/// URL support.
@MainActor
public final class FlowDeepLinkEffectHandler<R: Route> {
    public enum Result: Sendable, Equatable {
        /// URL matched and the plan was applied. The resulting flow
        /// path is attached for caller inspection / logging.
        case executed(plan: FlowPlan<R>, path: [RouteStep<R>])
        /// URL matched, but applying the plan was rejected by the
        /// underlying authority. `path` is the authority's committed-state
        /// snapshot at the point of rejection, while `reason` preserves its
        /// typed refusal.
        case applicationRejected(
            plan: FlowPlan<R>,
            path: [RouteStep<R>],
            reason: FlowRejectionReason
        )
        /// Authentication gate deferred the URL; caller should replay
        /// via ``resumePendingDeepLinkIfAllowed(_:)``.
        case pending(FlowPendingDeepLink<R>)
        /// URL rejected by scheme or host validation.
        case rejected(reason: DeepLinkRejectionReason)
        /// No mapping handled the URL.
        case unhandled(url: URL)
        /// String input could not be parsed as a URL.
        case invalidURL(input: String)
        /// The supplied effect carried no URL.
        case missingDeepLinkURL
        /// `resumePendingDeepLink` was called but nothing was queued.
        case noPendingDeepLink
    }

    private let pipeline: FlowDeepLinkPipeline<R>
    private let applier: any FlowPlanApplier<R>
    private var pendingReplaySlot = PendingReplaySlot<FlowPendingDeepLink<R>>()
    private var traceRecorder: InternalExecutionTraceRecorder?

    public var pendingDeepLink: FlowPendingDeepLink<R>? {
        pendingReplaySlot.current
    }

    public init(
        pipeline: FlowDeepLinkPipeline<R>,
        applier: any FlowPlanApplier<R>
    ) {
        self.pipeline = pipeline
        self.applier = applier
        self.traceRecorder = nil
    }

    /// Processes a URL through the pipeline and applies the outcome.
    @discardableResult
    public func handle(_ url: URL) -> Result {
        InternalExecutionTrace.withSpan(
            domain: .deepLink,
            operation: "handle",
            recorder: traceRecorder,
            metadata: ["url": url.absoluteString]
        ) {
            switch pipeline.decide(for: url) {
            case .rejected(let reason):
                return .rejected(reason: reason)
            case .unhandled(let unhandledURL):
                return .unhandled(url: unhandledURL)
            case .pending(let pending):
                pendingReplaySlot.replace(with: pending)
                return .pending(pending)
            case .flowPlan(let plan):
                pendingReplaySlot.replace(with: nil)
                return result(for: plan)
            }
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }

    @discardableResult
    public func handle(_ urlString: String) -> Result {
        guard let url = URL(string: urlString) else {
            return .invalidURL(input: urlString)
        }
        return handle(url)
    }

    /// Replays a previously deferred pending deep link by
    /// re-consulting the authentication policy. If the gate now
    /// permits it, the plan is applied.
    @discardableResult
    public func resumePendingDeepLink() -> Result {
        InternalExecutionTrace.withSpan(
            domain: .deepLink,
            operation: "resumePendingDeepLink",
            recorder: traceRecorder
        ) {
            guard let ticket = pendingReplaySlot.capture() else {
                return .noPendingDeepLink
            }
            return result(for: ticket, externallyAuthorized: true)
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }

    /// Allows the caller to await either a throwing or nonthrowing live
    /// authentication probe before re-evaluating the gate. A pending request
    /// replaced while the probe is suspended remains pending, even when the
    /// replacement has the same URL and plan.
    @discardableResult
    public func resumePendingDeepLinkIfAllowed(
        _ authorize: @escaping @MainActor @Sendable (FlowPendingDeepLink<R>) async throws -> Bool
    ) async rethrows -> Result {
        try await InternalExecutionTrace.withSpan(
            domain: .deepLink,
            operation: "resumePendingDeepLinkIfAllowed",
            recorder: traceRecorder
        ) {
            guard let ticket = pendingReplaySlot.capture() else {
                return .noPendingDeepLink
            }
            let isAuthorized = try await authorize(ticket.value)
            return result(for: ticket, externallyAuthorized: isAuthorized)
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }

    public func clearPendingDeepLink() {
        pendingReplaySlot.replace(with: nil)
    }

    func installTraceRecorder(_ recorder: InternalExecutionTraceRecorder?) {
        self.traceRecorder = recorder
    }

    /// Restores a previously persisted pending deep link (for
    /// example, one decoded at launch via
    /// `FlowPendingDeepLinkPersistence.decode(_:)`). After calling
    /// this, `resumePendingDeepLink()` / `resumePendingDeepLinkIfAllowed(_:)`
    /// re-consult the authentication policy and apply the stored
    /// plan if permitted.
    public func restore(pending: FlowPendingDeepLink<R>) {
        pendingReplaySlot.replace(with: pending)
    }

    // MARK: - Internals

    private func canResume(_ pending: FlowPendingDeepLink<R>) -> Bool {
        pipeline.canResume(pending.gatedRoute)
    }

    private func result(
        for ticket: PendingReplaySlot<FlowPendingDeepLink<R>>.Ticket,
        externallyAuthorized: Bool
    ) -> Result {
        guard pendingReplaySlot.isCurrent(ticket) else {
            return result(for: pendingReplaySlot.resolve(ticket, allowReplay: false))
        }

        let allowReplay = externallyAuthorized && canResume(ticket.value)
        return result(for: pendingReplaySlot.resolve(ticket, allowReplay: allowReplay))
    }

    private func result(
        for resolution: PendingReplaySlot<FlowPendingDeepLink<R>>.Resolution
    ) -> Result {
        switch resolution {
        case .noPending:
            return .noPendingDeepLink
        case .pending(let pending):
            return .pending(pending)
        case .replay(let pending):
            return result(for: pending.plan)
        }
    }

    private func result(for plan: FlowPlan<R>) -> Result {
        switch applier.apply(plan) {
        case .applied(let path):
            return .executed(plan: plan, path: path)
        case .rejected(let currentPath, let reason):
            return .applicationRejected(plan: plan, path: currentPath, reason: reason)
        }
    }

    private static func traceOutcome(for result: Result) -> String {
        switch result {
        case .executed:
            return "executed"
        case .applicationRejected:
            return "applicationRejected"
        case .pending:
            return "pending"
        case .rejected:
            return "rejected"
        case .unhandled:
            return "unhandled"
        case .invalidURL:
            return "invalidURL"
        case .missingDeepLinkURL:
            return "missingDeepLinkURL"
        case .noPendingDeepLink:
            return "noPendingDeepLink"
        }
    }
}

/// Convenience initializer bridging `FlowPlanApplier` through any
/// `FlowDeepLinkEffect` source (e.g. an InnoFlow effect wrapper).
public extension FlowDeepLinkEffectHandler {
    @discardableResult
    func handle<E: DeepLinkEffect>(_ effect: E) -> Result {
        guard let url = effect.deepLinkURL else {
            return .missingDeepLinkURL
        }
        return handle(url)
    }
}
