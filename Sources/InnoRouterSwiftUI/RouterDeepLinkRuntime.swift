// MARK: - RouterDeepLinkHandling.swift
// InnoRouterSwiftUI - macro-first incoming URL arbitration
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation
import OSLog

import InnoRouterCore
import InnoRouterDeepLink

@MainActor
final class RouterDeepLinkSource: Sendable {}

@MainActor
final class RouterDeepLinkArbiter: Sendable {
    private struct Candidate {
        let source: RouterDeepLinkSource
        let depth: Int
        let action: @MainActor @Sendable () -> Void
    }

    private static let logger = Logger(
        subsystem: "io.innosquad.innorouter",
        category: "macro-first-deep-link"
    )

    private var pending: [URL: Candidate] = [:]
    private var scheduledURLs: Set<URL> = []
    private var ambiguousURLs: Set<URL> = []

    func submit(
        url: URL,
        source: RouterDeepLinkSource,
        depth: Int,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        if let current = pending[url] {
            if current.source === source {
                return
            }
            if depth < current.depth {
                pending[url] = Candidate(
                    source: source,
                    depth: depth,
                    action: action
                )
            } else if depth == current.depth, ambiguousURLs.insert(url).inserted {
                Self.logger.warning(
                    "Multiple macro-first hosts resolved one incoming URL at the same nesting depth; the first candidate will handle it."
                )
            }
        } else {
            pending[url] = Candidate(
                source: source,
                depth: depth,
                action: action
            )
        }

        guard scheduledURLs.insert(url).inserted else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.flush(url)
        }
    }

    func flush(_ url: URL) {
        scheduledURLs.remove(url)
        ambiguousURLs.remove(url)
        pending.removeValue(forKey: url)?.action()
    }
}

@MainActor
private final class RouterDeepLinkWeakArbiter: Sendable {
    weak var value: RouterDeepLinkArbiter?

    init(_ value: RouterDeepLinkArbiter) {
        self.value = value
    }
}

@MainActor
enum RouterDeepLinkSceneArbiterRegistry {
    private static var arbiters: [String: RouterDeepLinkWeakArbiter] = [:]

    static func arbiter(for sceneIdentifier: String) -> RouterDeepLinkArbiter {
        arbiters = arbiters.filter { $0.value.value != nil }
        if let arbiter = arbiters[sceneIdentifier]?.value {
            return arbiter
        }
        let arbiter = RouterDeepLinkArbiter()
        arbiters[sceneIdentifier] = RouterDeepLinkWeakArbiter(arbiter)
        return arbiter
    }
}

struct RouterDeepLinkContext: Sendable {
    let arbiter: RouterDeepLinkArbiter
    let depth: Int
}

@MainActor
@discardableResult
func submitRouterDeepLink<R: Route>(
    _ routeType: R.Type,
    url: URL,
    context: RouterDeepLinkContext,
    source: RouterDeepLinkSource,
    action: @escaping @MainActor @Sendable (R) -> Void
) -> Bool {
    guard let resolver = routeType as? any DeepLinkRoute.Type,
          let route = resolver.resolveDeepLink(url) as? R else {
        return false
    }
    context.arbiter.submit(
        url: url,
        source: source,
        depth: context.depth
    ) {
        action(route)
    }
    return true
}

/// Observable result of executing an external URL through one router store.
///
/// The same value is returned by explicit store handling and emitted by a
/// macro-first host, so applications only need one link-result vocabulary.
public enum RouterLinkExecution<R: Route>: Sendable, Equatable {
    case rejected(url: URL, reason: DeepLinkRejectionReason)
    case unhandled(url: URL)
    case pending(PendingRouterLink<R>)
    case completed(plan: RouterPlan<R>, outcome: RouterOutcome<R>)
}

/// Determines how a new deferred link interacts with an occupied slot.
public enum RouterPendingLinkReplacementPolicy: Sendable, Hashable {
    /// Keep the first pending intent until it is resumed or cancelled.
    case keepExisting
    /// Replace the previous intent with the most recent external request.
    case replaceExisting
}

/// Result of offering a deferred link to ``RouterPendingLinkSlot``.
public enum RouterPendingLinkSubmission<R: Route>: Sendable, Equatable {
    case stored(PendingRouterLink<R>)
    case keptExisting(PendingRouterLink<R>)
    case replaced(previous: PendingRouterLink<R>, current: PendingRouterLink<R>)
}

/// Determines when an attempted pending-link continuation leaves its slot.
public enum RouterPendingLinkConsumptionPolicy: Sendable, Hashable {
    /// Consume only when the canonical plan was applied or already current.
    case onAcceptance
    /// Consume after any terminal store outcome, including policy rejection.
    case always
}

/// One explicit, observable continuation slot for authentication-gated links.
///
/// The slot owns no navigation state and never bypasses ``RouterStore``
/// policies. Applications may retain it beside session state, submit values
/// received from ``RouterLinkExecution/pending(_:)``, then resume after login.
@MainActor
@Observable
public final class RouterPendingLinkSlot<R: Route> {
    private final class OwnedResume {
        let generation: UInt64
        weak var store: RouterStore<R>?
        let transitionID: RouterTransitionID

        init(
            generation: UInt64,
            store: RouterStore<R>,
            transitionID: RouterTransitionID
        ) {
            self.generation = generation
            self.store = store
            self.transitionID = transitionID
        }
    }

    public private(set) var pending: PendingRouterLink<R>?
    @ObservationIgnored private var generation: UInt64
    @ObservationIgnored private var ownedResumes: [UUID: OwnedResume] = [:]
    @ObservationIgnored package var durableLifetime: RouterPendingLinkLifetimeState?
    @ObservationIgnored private var durableClock: (@Sendable () -> Date)?
    @ObservationIgnored private var durableMaximumAge: Duration?

    package func configureDurableLifetime(lifetime: Duration?, now: @escaping @Sendable () -> Date) {
        durableClock = now
        durableMaximumAge = lifetime
        if let current = durableLifetime {
            durableLifetime = .init(originatedAt: current.originatedAt, lastObservedAt: current.lastObservedAt, lifetime: lifetime, now: now)
        } else if pending != nil {
            startDurableLifetime()
        }
    }

    package func restoreDurableLifetime(originatedAt: Date, lastObservedAt: Date) {
        guard let durableClock else { return }
        durableLifetime = .init(originatedAt: originatedAt, lastObservedAt: lastObservedAt, lifetime: durableMaximumAge, now: durableClock)
    }

    private func startDurableLifetime() {
        guard let durableClock else { durableLifetime = nil; return }
        let origin = durableClock()
        durableLifetime = .init(originatedAt: origin, lastObservedAt: origin, lifetime: durableMaximumAge, now: durableClock)
    }

    package var mutationGeneration: UInt64 { generation }

    public init(_ pending: PendingRouterLink<R>? = nil) {
        self.pending = pending
        generation = pending == nil ? 0 : 1
    }

    @discardableResult
    public func submit(
        _ link: PendingRouterLink<R>,
        replacing policy: RouterPendingLinkReplacementPolicy = .replaceExisting
    ) -> RouterPendingLinkSubmission<R> {
        compactOwnedResumes()
        guard let current = pending else {
            pending = link
            startDurableLifetime()
            generation &+= 1
            return .stored(link)
        }
        switch policy {
        case .keepExisting:
            return .keptExisting(current)
        case .replaceExisting:
            pending = link
            startDurableLifetime()
            generation &+= 1
            return .replaced(previous: current, current: link)
        }
    }

    /// Cancels and returns the currently retained continuation.
    @discardableResult
    public func cancel() -> PendingRouterLink<R>? {
        compactOwnedResumes()
        guard let pending else { return nil }
        cancelOwnedResumes(for: generation)
        clearPending()
        return pending
    }

    /// Revalidates retained URL intent with the current pipeline when supplied.
    ///
    /// A rejected plan remains pending by default so the application can
    /// resolve another prerequisite or cancel it explicitly. If a newer link
    /// replaces this one while policies suspend, the newer value is preserved.
    public func resume(
        on store: RouterStore<R>,
        using pipeline: RouterLinkPipeline<R>? = nil,
        source: RouterTransitionSource = .deepLink,
        consuming policy: RouterPendingLinkConsumptionPolicy = .onAcceptance
    ) async -> RouterLinkExecution<R>? {
        compactOwnedResumes()
        guard let link = pending else { return nil }
        let retainedLifetime = durableLifetime
        if let retainedLifetime {
            do { _ = try retainedLifetime.validate(link: link) }
            catch let failure as RouterPendingLinkLifetimeFailure {
                let outcome = store.reject(store.reserveTransitionID(), reason: .pendingLinkLifetime(failure), context: .init(source: source), action: .apply(link.plan))
                return .completed(plan: link.plan, outcome: outcome)
            } catch {
                let outcome = store.reject(store.reserveTransitionID(), reason: .pendingLinkLifetime(.init(code: .invalidTimestamp)), context: .init(source: source), action: .apply(link.plan))
                return .completed(plan: link.plan, outcome: outcome)
            }
        }
        let resumedGeneration = generation
        let operationID = UUID()
        let transitionID = store.reserveTransitionID()
        ownedResumes[operationID] = OwnedResume(
            generation: resumedGeneration,
            store: store,
            transitionID: transitionID
        )
        let execution = await store.resume(
            link,
            using: pipeline,
            source: source,
            transitionID: transitionID,
            executionPrecondition: { [weak self] _ in
                guard self?.ownedResumes[operationID] != nil else {
                    return .cancelled
                }
                if let retainedLifetime {
                    do { _ = try retainedLifetime.validate(link: link) }
                    catch let failure as RouterPendingLinkLifetimeFailure { return .pendingLinkLifetime(failure) }
                    catch { return .pendingLinkLifetime(.init(code: .invalidTimestamp)) }
                }
                return nil
            }
        )
        if case .completed(_, .deferred) = execution {
            // The Store owns the complete request family, including future
            // deferrals created while this logical resume continues.
        } else {
            ownedResumes.removeValue(forKey: operationID)
        }
        guard generation == resumedGeneration else { return execution }

        switch policy {
        case .always:
            clearPending()
        case .onAcceptance:
            if execution.wasAccepted {
                clearPending()
            }
        }
        return execution
    }

    private func clearPending() {
        pending = nil
        durableLifetime = nil
        generation &+= 1
    }

    private func cancelOwnedResumes(for generation: UInt64) {
        let cancelled = ownedResumes.filter { $0.value.generation == generation }
        for operationID in cancelled.keys {
            ownedResumes.removeValue(forKey: operationID)
        }
        for resume in cancelled.values {
            guard let store = resume.store else { continue }
            store.cancelRequestFamily(resume.transitionID)
        }
    }

    private func compactOwnedResumes() {
        ownedResumes = ownedResumes.filter { _, resume in
            guard let store = resume.store else { return false }
            return store.hasRequestFamily(resume.transitionID)
        }
    }
}

public extension RouterStore {
    /// Admits a URL once, then checks authorization at actual Store execution.
    func handle(
        _ url: URL,
        using pipeline: RouterLinkPipeline<R>,
        source: RouterTransitionSource = .deepLink
    ) async -> RouterLinkExecution<R> {
        await handle(url, using: pipeline, source: source, transitionID: reserveTransitionID(), executionPrecondition: nil)
    }

    private func handle(
        _ url: URL,
        using pipeline: RouterLinkPipeline<R>,
        source: RouterTransitionSource,
        transitionID: RouterTransitionID,
        executionPrecondition: RouterRequestPrecondition<R>?,
        expectedPending: PendingRouterLink<R>? = nil
    ) async -> RouterLinkExecution<R> {
        switch pipeline.admittedDecision(for: url) {
        case .rejected(let reason): return .rejected(url: url, reason: reason)
        case .unhandled: return .unhandled(url: url)
        case .matched(let request):
            if expectedPending?.isRevalidationRequired == true,
               authorization == nil, pipeline.authorizationConfiguration == nil {
                return .rejected(url: url, reason: .authorization(.init(code: .revalidationRequired)))
            }
            guard expectedPending?.matchesIntent(of: request) != false else {
                return .rejected(url: url, reason: .authorization(.init(code: .intentChanged)))
            }
            // Legacy durable payloads may predate matchedRoute. Their retained
            // protected route remains intent and cannot disappear during resume.
            let originalTargets = (request.matchedRoute.map { [$0] } ?? [])
                + (expectedPending.map { [$0.gatedRoute] } ?? [])
            let authorization = RouterRequestAuthorization(
                matchedRoutes: originalTargets,
                configuration: pipeline.authorizationConfiguration
            )
            let outcome = await perform(
                .apply(request.plan), context: .init(source: source),
                expectedRevision: nil, bypassesPolicies: false,
                transitionID: transitionID, authorization: authorization,
                executionPrecondition: executionPrecondition
            )
            if case .rejected(_, _, _, .authorization(let failure)) = outcome,
               failure.code == .denied,
               let gated = authorization.deniedRoute {
                return .pending(.init(
                    url: url, gatedRoute: gated, plan: request.plan,
                    matchedRoute: request.matchedRoute, isRevalidationRequired: true
                ))
            }
            return .completed(plan: request.plan, outcome: outcome)
        }
    }

    /// Explicit resume starts a fresh admission against the current pipeline.
    /// Persisted plans never carry a prior grant, generation, or parser result.
    func resume(
        _ pending: PendingRouterLink<R>,
        using pipeline: RouterLinkPipeline<R>? = nil,
        source: RouterTransitionSource = .deepLink
    ) async -> RouterLinkExecution<R> {
        await resume(pending, using: pipeline, source: source, transitionID: reserveTransitionID(), executionPrecondition: nil)
    }

    package func resume(
        _ pending: PendingRouterLink<R>,
        using pipeline: RouterLinkPipeline<R>? = nil,
        source: RouterTransitionSource,
        transitionID: RouterTransitionID,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterLinkExecution<R> {
        if let pipeline {
            return await handle(pending.url, using: pipeline, source: source, transitionID: transitionID, executionPrecondition: executionPrecondition, expectedPending: pending)
        }
        guard !pending.isRevalidationRequired && authorization == nil else {
            let outcome = reject(
                transitionID, reason: .authorization(.init(code: .revalidationRequired)),
                context: .init(source: source), action: .apply(pending.plan)
            )
            return .completed(plan: pending.plan, outcome: outcome)
        }
        let outcome = await perform(
            .apply(pending.plan), context: .init(source: source),
            expectedRevision: nil, bypassesPolicies: false,
            transitionID: transitionID,
            authorization: .init(matchedRoutes: pending.matchedRoute.map { [$0] } ?? [pending.gatedRoute]),
            executionPrecondition: executionPrecondition
        )
        return .completed(plan: pending.plan, outcome: outcome)
    }
}

public extension PendingRouterLink {
    /// Convenience continuation when an application does not need a slot.
    @MainActor
    func resume(
        on store: RouterStore<R>,
        using pipeline: RouterLinkPipeline<R>? = nil,
        source: RouterTransitionSource = .deepLink
    ) async -> RouterLinkExecution<R> {
        await store.resume(self, using: pipeline, source: source)
    }
}

private extension RouterLinkExecution {
    var wasAccepted: Bool {
        guard case .completed(_, let outcome) = self else { return false }
        switch outcome {
        case .applied, .unchanged:
            return true
        case .deferred, .rejected:
            return false
        }
    }
}

/// Connects a ``RouterLinkPipeline`` to a macro-first host.
///
/// Authentication deferral and admission failures are surfaced through
/// `onEvent`; accepted plans are applied atomically by the host's one store.
public struct RouterLinkHandling<R: Route>: Sendable {
    private let admit: @Sendable (URL) -> RouterLinkAdmission<R>
    fileprivate let authorization: RouterAuthorizationConfiguration<R>?
    fileprivate let onEvent: @MainActor @Sendable (RouterLinkExecution<R>) -> Void

    public init(
        pipeline: RouterLinkPipeline<R>,
        onEvent: @escaping @MainActor @Sendable (RouterLinkExecution<R>) -> Void = { _ in }
    ) {
        self.admit = pipeline.admittedDecision(for:)
        self.authorization = pipeline.authorizationConfiguration
        self.onEvent = onEvent
    }

    fileprivate func admittedDecision(for url: URL) -> RouterLinkAdmission<R> { admit(url) }
}

/// The submission path used by the native onOpenURL modifier.
@MainActor
func submitRouterPlanLink<R: Route>(
    _ routeType: R.Type,
    url: URL,
    scope: RouterScope<R>,
    context: RouterDeepLinkContext,
    source: RouterDeepLinkSource,
    handling: RouterLinkHandling<R>?,
    fallbackPlan: @escaping @MainActor @Sendable (R, RouterState<R>) throws -> RouterPlan<R>
) {
    let admittedDecision: RouterLinkAdmission<R>
    if let handling {
        admittedDecision = handling.admittedDecision(for: url)
    } else {
        guard let resolver = routeType as? any DeepLinkRoute.Type,
              let route = resolver.resolveDeepLink(url) as? R,
              let state = scope.state,
              let plan = try? fallbackPlan(route, state) else { return }
        admittedDecision = .matched(RouterAdmittedLink(plan: plan, matchedRoute: route))
    }
    if case .unhandled = admittedDecision {
        handling?.onEvent(.unhandled(url: url))
        return
    }
    let authorization: RouterRequestAuthorization<R>?
    if case .matched(let request) = admittedDecision {
        authorization = .init(
            matchedRoutes: request.matchedRoute.map { [$0] } ?? [],
            configuration: handling?.authorization
        )
    } else {
        authorization = nil
    }
    let executionPrecondition = scope.captureLinkAuthorizationPrecondition(request: authorization)
    context.arbiter.submit(url: url, source: source, depth: context.depth) {
        switch admittedDecision {
        case .rejected(let reason):
            handling?.onEvent(.rejected(url: url, reason: reason))
        case .unhandled:
            handling?.onEvent(.unhandled(url: url))
        case .matched(let request):
            Task { @MainActor in
                let outcome = await scope.performRoot(
                    .apply(request.plan), context: .init(source: .deepLink),
                    expectedRevision: nil, executionPrecondition: executionPrecondition,
                    authorization: authorization
                )
                if case .rejected(_, _, _, .authorization(let failure)) = outcome,
                   failure.code == .denied,
                   let gated = authorization?.deniedRoute {
                    handling?.onEvent(.pending(.init(
                        url: url, gatedRoute: gated, plan: request.plan,
                        matchedRoute: request.matchedRoute, isRevalidationRequired: true
                    )))
                } else {
                    handling?.onEvent(.completed(plan: request.plan, outcome: outcome))
                }
            }
        }
    }
}
