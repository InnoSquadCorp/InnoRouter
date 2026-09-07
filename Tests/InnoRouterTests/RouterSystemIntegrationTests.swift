import Foundation
import Testing

import InnoRouter

@MainActor
private final class RouterDiagnosticRecorder: Sendable {
    var events: [RouterDiagnosticEvent] = []
}

@Suite("Router system integration")
struct RouterSystemIntegrationTests {
    private enum SystemRoute: Route, DeepLinkRoute {
        case home
        case detail(String)

        static func resolveDeepLink(_ url: URL) -> SystemRoute? {
            guard url.scheme == "innorouter", url.host == "app" else { return nil }
            let segments = url.path.split(separator: "/")
            guard segments.count == 2, segments[0] == "detail" else { return nil }
            return .detail(String(segments[1]))
        }

        func deepLinkURL(origin: DeepLinkOrigin) -> URL? {
            switch self {
            case .home:
                return DeepLinkURLBuilder.makeURL(origin: origin, pattern: "/home")
            case .detail(let id):
                return DeepLinkURLBuilder.makeURL(
                    origin: origin,
                    pattern: "/detail/:id",
                    parameters: [.init(name: "id", value: id)]
                )
            }
        }
    }

    private let origin = DeepLinkOrigin(scheme: "innorouter", host: "app")!

    @Test("App Intent builder renders the same canonical route URL")
    func appIntentURL() throws {
        let builder = RouterOpenURLIntentBuilder<SystemRoute>(origin: origin)

        #expect(builder.url(for: .detail("42"))?.absoluteString == "innorouter://app/detail/42")
        #expect(builder.intent(for: .detail("42")) != nil)
    }

    @Test("Shortcut catalogs retain stable IDs while concrete phrases stay app-owned")
    func shortcutCatalog() {
        let catalog = RouterShortcutCatalog(
            origin: origin,
            entries: [
                RouterShortcutRoute(id: "detail-42", route: SystemRoute.detail("42")),
                RouterShortcutRoute(id: "home", route: SystemRoute.home),
            ]
        )

        #expect(catalog.route(for: "detail-42") == .detail("42"))
        #expect(catalog.url(for: "detail-42")?.absoluteString == "innorouter://app/detail/42")
        #expect(catalog.intent(for: "detail-42") != nil)
        #expect(catalog.route(for: "missing") == nil)
    }

    @Test("Observability emits structural events without route payloads")
    @MainActor
    func payloadSafeObservability() async throws {
        let recorder = RouterDiagnosticRecorder()
        let observability = RouterObservability<SystemRoute> { event in
            recorder.events.append(event)
        }
        let configuration = RouterStoreConfiguration<SystemRoute>()
            .observing(observability)
        let store = RouterStore<SystemRoute>(configuration: configuration)

        _ = await store.perform(.push(.detail("never-log-this")))
        _ = await store.perform(
            .pop(count: 0),
            context: .init(source: .appIntent)
        )
        _ = await store.perform(
            .pop(count: 99),
            context: .init(source: .system)
        )

        #expect(
            recorder.events.map(\.kind) == [
                .started,
                .committed,
                .unchanged,
                .rejectedMutation,
            ]
        )
        #expect(
            recorder.events.map(\.source) == [
                .application,
                .application,
                .appIntent,
                .system,
            ]
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(recorder.events),
            as: UTF8.self
        )
        #expect(!encoded.contains("never-log-this"))
    }

    @Test("Policy deferral is diagnostic information, not a rejection")
    @MainActor
    func deferredPolicyDiagnostic() async {
        let recorder = RouterDiagnosticRecorder()
        let deferralID = RouterDeferralID()
        let observability = RouterObservability<SystemRoute> { event in
            recorder.events.append(event)
        }
        let configuration = RouterStoreConfiguration<SystemRoute>(
            policies: [
                RouterPolicy(name: "approval") { _ in
                    .deferRequest(deferralID)
                }
            ]
        ).observing(observability)
        let store = RouterStore<SystemRoute>(configuration: configuration)

        _ = await store.perform(.push(.home))

        #expect(
            recorder.events.map(\.kind) == [
                .started,
                .policyDeferred,
                .deferred,
            ]
        )
        #expect(!recorder.events.map(\.kind).contains(.policyRejected))
    }

    @Test("Observability classifies every lifecycle and rejection without payloads")
    @MainActor
    func exhaustiveObservabilityClassification() throws {
        let first = RouterDiagnosticRecorder()
        let second = RouterDiagnosticRecorder()
        let combined = RouterObservability<SystemRoute>.combined([
            RouterObservability { first.events.append($0) },
            RouterObservability { second.events.append($0) },
        ])
        let id = RouterTransitionID()
        let deferralID = RouterDeferralID()
        let state = RouterState<SystemRoute>.rootStack
        let context = RouterTransitionContext(source: .inspector)
        let transition = RouterTransition(
            id: id,
            action: .push(.home),
            initialState: state,
            proposedState: .rootStack(path: [.home]),
            initialRevision: 7,
            context: context
        )
        let deferral = RouterDeferredTransition(
            id: deferralID,
            transitionID: id,
            policy: "approval",
            initialRevision: 7,
            source: .inspector
        )

        let lifecycle: [RouterEvent<SystemRoute>] = [
            .started(transition),
            .policyPrepared(transitionID: id, policy: "allow", decision: .allow),
            .policyPrepared(transitionID: id, policy: "reject", decision: .reject("denied")),
            .policyPrepared(transitionID: id, policy: "defer", decision: .deferRequest(deferralID)),
            .committed(
                transitionID: id,
                before: state,
                after: .rootStack(path: [.home]),
                revision: 8,
                context: context
            ),
            .unchanged(transitionID: id, state: state, revision: 8, context: context),
            .deferred(
                transitionID: id,
                state: state,
                revision: 8,
                deferral: deferral,
                context: context
            ),
            .platformAdapted(
                eventID: id,
                adaptation: .tabBadgeVisualUnavailable(scope: "home", count: 1),
                revision: 8
            ),
        ]
        for event in lifecycle {
            combined.record(event)
        }

        let reasons: [RouterRejectionReason] = [
            .mutation(.invalidPopCount(requested: 2, available: 0, scope: .root)),
            .policy(name: "gate", message: "denied"),
            .busy(activeTransition: RouterTransitionID()),
            .coalesced(existingTransition: RouterTransitionID()),
            .superseded(replacementTransition: RouterTransitionID()),
            .queueOverflow(limit: 2),
            .policyTimedOut(name: "slow"),
            .deferralConflict(deferralID),
            .deferralNotFound(deferralID),
            .deferralCapacityExceeded(limit: 1),
            .deferralExpired(deferralID),
            .deferralEvicted(deferralID),
            .staleState(expectedRevision: 1, actualRevision: 2),
            .cancelled,
            .missingAuthority(routeType: "SystemRoute"),
        ]
        for reason in reasons {
            combined.record(
                .rejected(
                    transitionID: id,
                    state: state,
                    revision: 8,
                    reason: reason,
                    context: context
                )
            )
        }

        let expectedKinds: [RouterDiagnosticEventKind] = [
            .started,
            .policyAllowed,
            .policyRejected,
            .policyDeferred,
            .committed,
            .unchanged,
            .deferred,
            .platformAdapted,
            .rejectedMutation,
            .rejectedPolicy,
            .rejectedBusy,
            .rejectedCoalesced,
            .rejectedSuperseded,
            .rejectedQueueOverflow,
            .rejectedPolicyTimeout,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedDeferral,
            .rejectedStaleState,
            .rejectedCancelled,
            .rejectedMissingAuthority,
        ]
        #expect(first.events.map(\.kind) == expectedKinds)
        #expect(second.events == first.events)
        #expect(first.events[1].policy == "allow")
        #expect(first.events[4].source == .inspector)
        #expect(first.events[4].revision == 8)

        let encoded = try JSONEncoder().encode(first.events)
        #expect(
            try JSONDecoder().decode([RouterDiagnosticEvent].self, from: encoded)
                == first.events
        )

        let logger = RouterObservability<SystemRoute>.osLog(
            subsystem: "io.innosquad.innorouter.tests",
            category: "classification"
        )
        logger.record(lifecycle[0])
        logger.record(lifecycle[4])
        logger.record(
            .rejected(
                transitionID: id,
                state: state,
                revision: 8,
                reason: .cancelled,
                context: context
            )
        )

        let signposts = RouterObservability<SystemRoute>.signposts(
            subsystem: "io.innosquad.innorouter.tests",
            category: "classification"
        )
        signposts.record(lifecycle[0])
        signposts.record(lifecycle[1])
        signposts.record(lifecycle[4])
        signposts.record(lifecycle[7])
    }

    @Test("Handoff continuation executes the complete plan with handoff provenance")
    @MainActor
    func handoffPipeline() async throws {
        let webOrigin = DeepLinkOrigin(scheme: "https", host: "app.example.com")!
        let store = RouterStore<SystemRoute>()
        let pipeline = RouterLinkPipeline<SystemRoute>(
            originPolicy: .allowlisted(schemes: ["https"], hosts: ["app.example.com"]),
            customResolver: { url in
                guard url.path == "/detail/42" else { return nil }
                return RouterPlan(state: .rootStack(path: [.home, .detail("42")]))
            }
        )
        let activity = NSUserActivity(activityType: "io.innosquad.test.route")
        activity.webpageURL = SystemRoute.detail("42").deepLinkURL(origin: webOrigin)
        var events = store.events.makeAsyncIterator()

        let execution = await continueRouterHandoff(
            activity,
            store: store,
            pipeline: pipeline
        )

        guard case .completed = execution else {
            Issue.record("Expected Handoff plan to complete")
            return
        }
        guard case .started(let transition) = await events.next() else {
            Issue.record("Expected a correlated router transition")
            return
        }
        #expect(transition.context.source == .handoff)
        #expect(store.state.root == .stack(path: [.home, .detail("42")]))
    }

    @Test("Handoff without a canonical URL is ignored")
    @MainActor
    func missingHandoffURL() async {
        let store = RouterStore<SystemRoute>()
        let pipeline = RouterLinkPipeline<SystemRoute>(
            originPolicy: .allowlisted(schemes: ["innorouter"], hosts: ["app"]),
            customResolver: { _ in RouterPlan(state: .rootStack) }
        )
        let activity = NSUserActivity(activityType: "io.innosquad.test.route")

        #expect(
            await continueRouterHandoff(activity, store: store, pipeline: pipeline) == nil
        )
        #expect(store.revision == 0)
    }

    @Test("Handoff configuration rejects custom-scheme origins before publication")
    func handoffRequiresUniversalLink() {
        #expect(
            RouterHandoffConfiguration<SystemRoute>(
                activityType: "io.innosquad.test.route",
                origin: origin,
                title: { _ in "Route" }
            ) == nil
        )
        #expect(
            RouterHandoffConfiguration<SystemRoute>(
                activityType: "io.innosquad.test.route",
                origin: DeepLinkOrigin(scheme: "https", host: "app.example.com")!,
                title: { _ in "Route" }
            ) != nil
        )
    }
}
