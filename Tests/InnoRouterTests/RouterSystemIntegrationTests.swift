import Foundation
import Testing

import InnoRouter

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

    @Test("Observability native adapters accept structural lifecycle events")
    @MainActor
    func nativeObservabilityAdapters() {
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
