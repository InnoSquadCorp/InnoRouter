import Foundation
import Synchronization
import Testing

import InnoRouterCore
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

@Suite("Plan link host admission")
@MainActor
struct RouterPlanLinkAdmissionTests {
    private enum Destination: String, Route {
        case home
        case account
    }

    @Test("The selected host preserves authentication intent and the losing host never authenticates")
    func winningHostRetainsOriginalTarget() async throws {
        let initial = try RouterState<Destination>(root: .container(.init(
            style: .tabs,
            selection: "home",
            branches: [RouterBranch(id: "home"), RouterBranch(id: "account")]
        )))
        let target = RouterPlan(state: try RouterReducer.reduce(.select("account"), from: initial))
        let store = RouterStore(initialState: initial)
        let arbiter = RouterDeepLinkArbiter()
        let winningMatches = Mutex(0)
        let winningAuthentications = Mutex(0)
        let losingAuthentications = Mutex(0)
        let (events, continuation) = AsyncStream<RouterLinkExecution<Destination>>.makeStream()
        defer { continuation.finish() }
        let winning = RouterLinkHandling(
            pipeline: RouterLinkPipeline<Destination>(
                originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
                matcher: DeepLinkMatcher {
                    DeepLinkMapping("/account") { _ in
                        winningMatches.withLock { $0 += 1 }
                        return Destination.account
                    }
                },
                authenticationPolicy: .configured(.init(
                    requiresAuthorization: { $0 == .account },
                    authorize: {
                        winningAuthentications.withLock { $0 += 1 }
                        return false
                    },
                    catalog: { .init(roots: [
                        .init(style: .tabs, branch: "home"): .home,
                        .init(style: .tabs, branch: "account"): .account
                    ]) }
                )),
                plan: { _ in target }
            ),
            onEvent: { continuation.yield($0) }
        )
        let losing = RouterLinkHandling(
            pipeline: RouterLinkPipeline<Destination>(
                originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
                matcher: DeepLinkMatcher {
                    DeepLinkMapping("/account") { _ in Destination.account }
                },
                authenticationPolicy: .configured(.init(
                    requiresAuthorization: { $0 == .account },
                    authorize: {
                        losingAuthentications.withLock { $0 += 1 }
                        return true
                    },
                    catalog: { .init(roots: [
                        .init(style: .tabs, branch: "home"): .home,
                        .init(style: .tabs, branch: "account"): .account
                    ]) }
                )),
                plan: { _ in target }
            ),
            onEvent: { _ in Issue.record("Losing host must not emit a terminal event") }
        )
        let url = try #require(URL(string: "router://app/account"))
        submitRouterPlanLink(
            Destination.self, url: url, scope: store.scope(),
            context: .init(arbiter: arbiter, depth: 1), source: RouterDeepLinkSource(),
            handling: losing, fallbackPlan: { _, _ in target }
        )
        submitRouterPlanLink(
            Destination.self, url: url, scope: store.scope(),
            context: .init(arbiter: arbiter, depth: 0), source: RouterDeepLinkSource(),
            handling: winning, fallbackPlan: { _, _ in target }
        )
        arbiter.flush(url)
        guard case .pending(let pending) = try await firstElement(
            from: events, what: "winning host authentication decision"
        ) else {
            Issue.record("Expected the winning protected selection-only link to remain pending")
            return
        }
        #expect(pending.gatedRoute == .account)
        #expect(pending.plan == target)
        #expect(store.state == initial)
        #expect(store.revision == 0)
        #expect(winningMatches.withLock { $0 } == 1)
        #expect(winningAuthentications.withLock { $0 } == 1)
        #expect(losingAuthentications.withLock { $0 } == 0)
    }

    @Test("Host arbitration does not transfer old-account intent into a new generation")
    func hostSubmissionCapturesGeneration() async throws {
        let session = HostAuthorizationSession()
        let store = RouterStore<Destination>(configuration: .init(authorization: .init(
            generation: { session.generation }, requiresAuthorization: { $0 == .account },
            authorize: { session.authenticationCalls += 1; return true }
        )))
        let arbiter = RouterDeepLinkArbiter()
        let target = RouterPlan<Destination>(state: .rootStack(path: [.account]))
        let (events, continuation) = AsyncStream<RouterLinkExecution<Destination>>.makeStream()
        defer { continuation.finish() }
        let handling = RouterLinkHandling(
            pipeline: RouterLinkPipeline<Destination>(
                originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
                matcher: DeepLinkMatcher { DeepLinkMapping("/account") { _ in Destination.account } }
            ), onEvent: { continuation.yield($0) }
        )
        let url = try #require(URL(string: "router://app/account"))
        submitRouterPlanLink(
            Destination.self, url: url, scope: store.scope(),
            context: .init(arbiter: arbiter, depth: 0), source: RouterDeepLinkSource(),
            handling: handling, fallbackPlan: { _, _ in target }
        )
        session.generation += 1
        arbiter.flush(url)
        guard case .completed(_, .rejected(_, _, _, .authorization(let failure))) = try await firstElement(
            from: events, what: "stale host submission"
        ) else {
            Issue.record("The URL submission must retain its old generation across arbitration")
            return
        }
        #expect(failure.code == .generationChanged)
        #expect(session.authenticationCalls == 0)
        #expect(store.revision == 0)
        #expect(store.state == .rootStack)
    }
}

@MainActor
private final class HostAuthorizationSession {
    var generation: UInt64 = 0
    var authenticationCalls = 0
}
