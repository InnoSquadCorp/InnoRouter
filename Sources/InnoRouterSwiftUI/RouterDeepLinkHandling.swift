// MARK: - RouterDeepLinkHandling.swift
// InnoRouterSwiftUI - macro-first incoming URL arbitration
// Copyright © 2026 Inno Squad. All rights reserved.

import Foundation
import Observation
import OSLog
import SwiftUI

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

extension EnvironmentValues {
    @Entry var routerDeepLinkContext: RouterDeepLinkContext?
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

@MainActor
private struct RouterDeepLinkHandlingModifier<R: Route>: ViewModifier {
    @Environment(\.routerDeepLinkContext) private var inheritedContext
    // SwiftUI shares one value for this key inside a Scene and isolates it
    // from other Scene instances. Nested hosts inherit the same arbiter
    // directly; sibling roots meet again through the scene registry.
    @SceneStorage("io.innosquad.innorouter.macro-first-deep-link-scene")
    private var sceneIdentifier = UUID().uuidString
    @State private var source = RouterDeepLinkSource()

    let routeType: R.Type
    let action: @MainActor @Sendable (R) -> Void

    func body(content: Content) -> some View {
        let context = RouterDeepLinkContext(
            arbiter: inheritedContext?.arbiter ??
                RouterDeepLinkSceneArbiterRegistry.arbiter(for: sceneIdentifier),
            depth: inheritedContext.map { $0.depth + 1 } ?? 0
        )
        content
            .environment(\.routerDeepLinkContext, context)
            .onOpenURL { url in
                submitRouterDeepLink(
                    routeType,
                    url: url,
                    context: context,
                    source: source,
                    action: action
                )
            }
    }
}

extension View {
    @MainActor
    func handleRouterDeepLinks<R: Route>(
        for routeType: R.Type,
        action: @escaping @MainActor @Sendable (R) -> Void
    ) -> some View {
        modifier(
            RouterDeepLinkHandlingModifier(
                routeType: routeType,
                action: action
            )
        )
    }
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
            generation &+= 1
            return .stored(link)
        }
        switch policy {
        case .keepExisting:
            return .keptExisting(current)
        case .replaceExisting:
            pending = link
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

    /// Replays the exact retained plan through the canonical store pipeline.
    ///
    /// A rejected plan remains pending by default so the application can
    /// resolve another prerequisite or cancel it explicitly. If a newer link
    /// replaces this one while policies suspend, the newer value is preserved.
    public func resume(
        on store: RouterStore<R>,
        source: RouterTransitionSource = .deepLink,
        consuming policy: RouterPendingLinkConsumptionPolicy = .onAcceptance
    ) async -> RouterLinkExecution<R>? {
        compactOwnedResumes()
        guard let link = pending else { return nil }
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
            source: source,
            transitionID: transitionID,
            executionPrecondition: { [weak self] _ in
                guard self?.ownedResumes[operationID] != nil else {
                    return .cancelled
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
    /// Resolves and executes a deep link, App Intent, or Handoff URL through
    /// the same exact-plan policy pipeline used by the SwiftUI host.
    func handle(
        _ url: URL,
        using pipeline: RouterLinkPipeline<R>,
        source: RouterTransitionSource = .deepLink
    ) async -> RouterLinkExecution<R> {
        switch await pipeline.decide(for: url) {
        case .rejected(let reason):
            return .rejected(url: url, reason: reason)
        case .unhandled:
            return .unhandled(url: url)
        case .pending(let pending):
            return .pending(pending)
        case .plan(let plan):
            let outcome = await perform(
                .apply(plan),
                context: .init(source: source)
            )
            return .completed(plan: plan, outcome: outcome)
        }
    }

    /// Resumes an authentication-gated link without resolving its URL again.
    ///
    /// The exact retained plan enters the same reduce, policy, and atomic
    /// commit path as an initially accepted link.
    func resume(
        _ pending: PendingRouterLink<R>,
        source: RouterTransitionSource = .deepLink
    ) async -> RouterLinkExecution<R> {
        await resume(
            pending,
            source: source,
            transitionID: reserveTransitionID(),
            executionPrecondition: nil
        )
    }

    package func resume(
        _ pending: PendingRouterLink<R>,
        source: RouterTransitionSource,
        transitionID: RouterTransitionID,
        executionPrecondition: RouterRequestPrecondition<R>?
    ) async -> RouterLinkExecution<R> {
        let outcome = await perform(
            .apply(pending.plan),
            context: .init(source: source),
            expectedRevision: nil,
            bypassesPolicies: false,
            transitionID: transitionID,
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
        source: RouterTransitionSource = .deepLink
    ) async -> RouterLinkExecution<R> {
        await store.resume(self, source: source)
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
    private let admit: @Sendable (URL) -> RouterLinkDecision<R>
    private let authenticate: @Sendable (URL, RouterPlan<R>) async -> RouterLinkDecision<R>
    fileprivate let onEvent: @MainActor @Sendable (RouterLinkExecution<R>) -> Void

    public init(
        pipeline: RouterLinkPipeline<R>,
        onEvent: @escaping @MainActor @Sendable (RouterLinkExecution<R>) -> Void = { _ in }
    ) {
        self.admit = pipeline.admittedDecision(for:)
        self.authenticate = { url, plan in
            await pipeline.authenticatedDecision(for: url, plan: plan)
        }
        self.onEvent = onEvent
    }

    fileprivate func admittedDecision(for url: URL) -> RouterLinkDecision<R> {
        admit(url)
    }

    fileprivate func authenticatedDecision(
        for url: URL,
        plan: RouterPlan<R>
    ) async -> RouterLinkDecision<R> {
        await authenticate(url, plan)
    }
}

@MainActor
private struct RouterPlanLinkHandlingModifier<R: Route>: ViewModifier {
    @Environment(\.routerDeepLinkContext) private var inheritedContext
    @SceneStorage("io.innosquad.innorouter.plan-deep-link-scene")
    private var sceneIdentifier = UUID().uuidString
    @State private var source = RouterDeepLinkSource()

    let routeType: R.Type
    let scope: RouterScope<R>
    let handling: RouterLinkHandling<R>?
    let fallbackPlan: @MainActor @Sendable (R, RouterState<R>) throws -> RouterPlan<R>

    func body(content: Content) -> some View {
        let context = RouterDeepLinkContext(
            arbiter: inheritedContext?.arbiter ??
                RouterDeepLinkSceneArbiterRegistry.arbiter(for: sceneIdentifier),
            depth: inheritedContext.map { $0.depth + 1 } ?? 0
        )
        content
            .environment(\.routerDeepLinkContext, context)
            .onOpenURL { url in
                submit(url, context: context)
            }
    }

    private func submit(_ url: URL, context: RouterDeepLinkContext) {
        let admittedDecision: RouterLinkDecision<R>
        if let handling {
            admittedDecision = handling.admittedDecision(for: url)
        } else {
            guard let resolver = routeType as? any DeepLinkRoute.Type,
                  let route = resolver.resolveDeepLink(url) as? R,
                  let state = scope.state,
                  let plan = try? fallbackPlan(route, state) else {
                return
            }
            admittedDecision = .plan(plan)
        }

        if case .unhandled = admittedDecision {
            handling?.onEvent(.unhandled(url: url))
            return
        }

        context.arbiter.submit(
            url: url,
            source: source,
            depth: context.depth
        ) {
            switch admittedDecision {
            case .rejected(let reason):
                handling?.onEvent(.rejected(url: url, reason: reason))
            case .unhandled:
                handling?.onEvent(.unhandled(url: url))
            case .pending(let pending):
                handling?.onEvent(.pending(pending))
            case .plan(let plan):
                Task { @MainActor in
                    let decision = if let handling {
                        await handling.authenticatedDecision(for: url, plan: plan)
                    } else {
                        RouterLinkDecision<R>.plan(plan)
                    }
                    await execute(decision, for: url)
                }
            }
        }
    }

    private func execute(
        _ decision: RouterLinkDecision<R>,
        for url: URL
    ) async {
        switch decision {
        case .rejected(let reason):
            handling?.onEvent(.rejected(url: url, reason: reason))
        case .unhandled:
            handling?.onEvent(.unhandled(url: url))
        case .pending(let pending):
            handling?.onEvent(.pending(pending))
        case .plan(let plan):
            let outcome = await scope.performRoot(
                .apply(plan),
                context: .init(source: .deepLink)
            )
            handling?.onEvent(.completed(plan: plan, outcome: outcome))
        }
    }
}

extension View {
    /// Applies accepted deep links as complete plans through one router store.
    @MainActor
    func handleRouterPlans<R: Route>(
        for routeType: R.Type,
        scope: RouterScope<R>,
        handling: RouterLinkHandling<R>?,
        fallbackPlan: @escaping @MainActor @Sendable (R, RouterState<R>) throws -> RouterPlan<R>
    ) -> some View {
        modifier(
            RouterPlanLinkHandlingModifier(
                routeType: routeType,
                scope: scope,
                handling: handling,
                fallbackPlan: fallbackPlan
            )
        )
    }
}
