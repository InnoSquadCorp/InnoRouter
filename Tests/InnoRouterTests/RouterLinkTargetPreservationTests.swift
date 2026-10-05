import Foundation
import Synchronization
import Testing

import InnoRouterCore
import InnoRouterDeepLink

@Suite("7.0 link target preservation")
struct RouterLinkTargetPreservationTests {
    private enum Destination: String, Route, Codable {
        case home
        case account
        case protectedDetail
    }

    private func tabPlan() throws -> RouterPlan<Destination> {
        RouterPlan(state: try RouterState(root: .container(
            RouterContainerState(
                style: .tabs,
                selection: "account",
                branches: [RouterBranch(id: "home"), RouterBranch(id: "account")]
            )
        )))
    }

    @Test("F1: selection-only planner retains the originally protected route")
    func selectedRootKeepsAuthenticationTarget() async throws {
        let target = try tabPlan()
        let pipeline = RouterLinkPipeline<Destination>(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/account") { _ in Destination.account }
            },
            authenticationPolicy: .configured(.init(
                requiresAuthorization: { $0 == .account },
                authorize: { false },
                catalog: { .init(roots: [.init(style: .tabs, branch: "account"): .account]) }
            )),
            plan: { _ in target }
        )
        let url = try #require(URL(string: "router://app/account"))
        #expect(await pipeline.decide(for: url) == .pending(
            PendingRouterLink(url: url, gatedRoute: .account, plan: target, matchedRoute: .account, isRevalidationRequired: true)
        ))
    }

    @Test("Control: an authenticated selection-only route remains accepted")
    func authenticatedSelectionControl() async throws {
        let target = try tabPlan()
        let pipeline = RouterLinkPipeline<Destination>(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/account") { _ in Destination.account }
            },
            authenticationPolicy: .configured(.init(
                requiresAuthorization: { $0 == .account },
                authorize: { true },
                catalog: { .init(roots: [.init(style: .tabs, branch: "account"): .account]) }
            )),
            plan: { _ in target }
        )
        #expect(await pipeline.decide(for: try #require(URL(string: "router://app/account"))) == .plan(target))
    }

    @Test("Control: a protected stack destination is still gated")
    func protectedStackControl() async throws {
        let pipeline = RouterLinkPipeline<Destination>(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/account") { _ in Destination.account }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .account },
                isAuthenticated: { false }
            )
        )
        guard case .pending(let pending) = await pipeline.decide(
            for: try #require(URL(string: "router://app/account"))
        ) else {
            Issue.record("Expected a protected stack destination to remain pending")
            return
        }
        #expect(pending.gatedRoute == .account)
        #expect(pending.plan.state.root == .stack(path: [.account]))
    }

    @Test("Original target preservation does not remove existing whole-plan checks")
    func originalAndMaterializedTargetUnion() async throws {
        let target = RouterPlan<Destination>(state: .rootStack(path: [.protectedDetail]))
        let pipeline = RouterLinkPipeline<Destination>(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/home") { _ in Destination.home }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .protectedDetail },
                isAuthenticated: { false }
            ),
            plan: { _ in target }
        )
        guard case .pending(let pending) = await pipeline.decide(
            for: try #require(URL(string: "router://app/home"))
        ) else {
            Issue.record("Expected materialized plan target to remain pending")
            return
        }
        #expect(pending.gatedRoute == .protectedDetail)
        #expect(pending.plan == target)
    }

    @Test("Unprotected route does not invoke authentication or parse the URL twice")
    func unprotectedAndSingleMatchControl() async throws {
        let matches = Mutex(0)
        let authentications = Mutex(0)
        let pipeline = RouterLinkPipeline<Destination>(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/home") { _ in
                    matches.withLock { $0 += 1 }
                    return Destination.home
                }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { $0 == .account },
                isAuthenticated: {
                    authentications.withLock { $0 += 1 }
                    return false
                }
            )
        )
        #expect(await pipeline.decide(for: try #require(URL(string: "router://app/home")))
            == .plan(RouterPlan(state: .rootStack(path: [.home]))))
        #expect(matches.withLock { $0 } == 1)
        #expect(authentications.withLock { $0 } == 0)
    }
    @Test("Split-phase admission preserves intent without a second resolver invocation")
    func synchronousAdmissionCarriesIntent() async throws {
        let matches = Mutex(0)
        let target = try tabPlan()
        let pipeline = RouterLinkPipeline<Destination>(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/account") { _ in
                    matches.withLock { $0 += 1 }
                    return Destination.account
                }
            },
            authenticationPolicy: .configured(.init(
                requiresAuthorization: { $0 == .account },
                authorize: { false },
                catalog: { .init(roots: [.init(style: .tabs, branch: "account"): .account]) }
            )),
            plan: { _ in target }
        )
        let url = try #require(URL(string: "router://app/account"))
        guard case .matched(let request) = pipeline.admittedDecision(for: url) else {
            Issue.record("Expected synchronous admission")
            return
        }
        #expect(request.matchedRoute == .account)
        #expect(request.plan == target)
        #expect(await pipeline.authenticatedDecision(for: url, request: request) == .pending(
            PendingRouterLink(url: url, gatedRoute: .account, plan: target, matchedRoute: .account, isRevalidationRequired: true)
        ))
        #expect(matches.withLock { $0 } == 1)
    }

    @Test("The original route and materialized duplicates are inspected once")
    func authenticationUnionDeduplicates() async throws {
        let inspected = Mutex<[Destination]>([])
        let pipeline = RouterLinkPipeline<Destination>(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/home") { _ in Destination.home }
            },
            authenticationPolicy: .required(
                shouldRequireAuthentication: { route in
                    inspected.withLock { $0.append(route) }
                    return false
                },
                isAuthenticated: { false }
            )
        )
        _ = await pipeline.decide(for: try #require(URL(string: "router://app/home")))
        #expect(inspected.withLock { $0 } == [.home])
    }
}
