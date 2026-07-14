// MARK: - FlowDeepLinkEffectHandler.swift
// InnoRouterDeepLinkEffects - composite URL → FlowStore.apply bridge
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import InnoRouterCore
@_exported import InnoRouterCore
@_exported import InnoRouterDeepLink

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
        /// underlying authority. `path` reflects the unchanged
        /// committed state after the rejection.
        case applicationRejected(plan: FlowPlan<R>, path: [RouteStep<R>])
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

    public private(set) var pendingDeepLink: FlowPendingDeepLink<R>?
    public let pipeline: FlowDeepLinkPipeline<R>
    private let applier: any FlowPlanApplier<R>
    private var traceRecorder: InternalExecutionTraceRecorder?

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
                self.pendingDeepLink = pending
                return .pending(pending)
            case .flowPlan(let plan):
                self.pendingDeepLink = nil
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
            guard let pending = pendingDeepLink else {
                return .noPendingDeepLink
            }
            guard canResume(pending) else {
                return .pending(pending)
            }
            self.pendingDeepLink = nil
            return result(for: pending.plan)
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }

    /// Async variant: allows the caller to await a live
    /// authentication probe (e.g. a token refresh) before
    /// re-evaluating the gate.
    @discardableResult
    public func resumePendingDeepLinkIfAllowed(
        _ authorize: @escaping @MainActor @Sendable (FlowPendingDeepLink<R>) async -> Bool
    ) async -> Result {
        await InternalExecutionTrace.withSpan(
            domain: .deepLink,
            operation: "resumePendingDeepLinkIfAllowed",
            recorder: traceRecorder
        ) {
            guard let pending = pendingDeepLink else {
                return .noPendingDeepLink
            }
            let captured = pending
            let isAuthorized = await authorize(captured)

            guard self.pendingDeepLink == captured else {
                if let current = self.pendingDeepLink {
                    return .pending(current)
                }
                return .noPendingDeepLink
            }

            guard isAuthorized else {
                return .pending(captured)
            }
            return resumePendingDeepLink()
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }

    /// Throwing async variant for auth probes that can fail before a
    /// boolean authorization decision is available.
    @discardableResult
    public func resumePendingDeepLinkIfAllowed(
        _ authorize: @escaping @MainActor @Sendable (FlowPendingDeepLink<R>) async throws -> Bool
    ) async rethrows -> Result {
        try await InternalExecutionTrace.withSpan(
            domain: .deepLink,
            operation: "resumePendingDeepLinkIfAllowed",
            recorder: traceRecorder
        ) {
            guard let pending = pendingDeepLink else {
                return .noPendingDeepLink
            }
            let captured = pending
            let isAuthorized = try await authorize(captured)

            guard self.pendingDeepLink == captured else {
                if let current = self.pendingDeepLink {
                    return .pending(current)
                }
                return .noPendingDeepLink
            }

            guard isAuthorized else {
                return .pending(captured)
            }
            return resumePendingDeepLink()
        } outcome: { result in
            Self.traceOutcome(for: result)
        }
    }

    public var hasPendingDeepLink: Bool {
        pendingDeepLink != nil
    }

    public func clearPendingDeepLink() {
        pendingDeepLink = nil
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
        self.pendingDeepLink = pending
    }

    // MARK: - Internals

    private func canResume(_ pending: FlowPendingDeepLink<R>) -> Bool {
        switch pipeline.authenticationPolicy {
        case .notRequired:
            return true
        case .required(let shouldRequireAuthentication, let isAuthenticated):
            if !shouldRequireAuthentication(pending.gatedRoute) {
                return true
            }
            return isAuthenticated()
        }
    }

    private func result(for plan: FlowPlan<R>) -> Result {
        switch applier.apply(plan) {
        case .applied(let path):
            return .executed(plan: plan, path: path)
        case .rejected(let currentPath):
            return .applicationRejected(plan: plan, path: currentPath)
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
