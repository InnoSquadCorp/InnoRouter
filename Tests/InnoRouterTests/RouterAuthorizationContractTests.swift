import Foundation
import Synchronization
import Testing

import InnoRouterCore
import InnoRouterDeepLink
@testable import InnoRouterSwiftUI

@Suite("Authoritative Store authorization", .timeLimit(.minutes(1)))
@MainActor
struct RouterAuthorizationContractTests {
    private enum R: String, Route, Codable { case home, account, storedSecret, detail, scene }

    @MainActor
    private final class Session {
        var generation: UInt64 = 0
        var allowed = false
        var calls = 0
        var catalog = RouterAuthorizationCatalog<R>()
        var gate: AuthorizationGate?

        func configuration() -> RouterAuthorizationConfiguration<R> {
            .init(
                generation: { self.generation },
                requiresAuthorization: { [.account, .storedSecret, .scene].contains($0) },
                authorize: {
                    self.calls += 1
                    if let gate = self.gate { await gate.wait() }
                    return self.allowed
                },
                catalog: { self.catalog }
            )
        }
    }

    private func tabs(selection: RouterScopeID = "home", storedSecret: Bool = false) throws -> RouterState<R> {
        try .init(root: .container(.init(
            style: .tabs, selection: selection,
            branches: [
                .init(id: "home"),
                .init(id: "account", node: .stack(path: storedSecret ? [.storedSecret] : []))
            ]
        )))
    }

    private func tabCatalog() -> RouterAuthorizationCatalog<R> {
        .init(roots: [
            .init(style: .tabs, branch: "home"): .home,
            .init(style: .tabs, branch: "account"): .account
        ])
    }

    private func pipeline(
        configuration: RouterAuthorizationConfiguration<R>? = nil,
        target: RouterPlan<R>,
        matched: R = .account,
        matches: AuthorizationCounter? = nil
    ) -> RouterLinkPipeline<R> {
        .init(
            originPolicy: .allowlisted(schemes: ["router"], hosts: ["app"]),
            matcher: DeepLinkMatcher {
                DeepLinkMapping("/intent") { _ in
                    matches?.increment()
                    return matched
                }
            },
            authenticationPolicy: configuration.map { .configured($0) } ?? .notRequired,
            plan: { _ in target }
        )
    }

    private var url: URL { URL(string: "router://app/intent")! }

    private func expectRejection(_ outcome: RouterOutcome<R>, _ code: RouterAuthorizationFailure.Code) {
        guard case .rejected(_, _, _, .authorization(let failure)) = outcome else {
            Issue.record("Expected an authorization rejection, received \(outcome)")
            return
        }
        #expect(failure.code == code)
    }

    @Test("A protected selected tab is checked in direct application without phantom state")
    func directPlanSelectedRoot() async throws {
        let session = Session()
        session.catalog = tabCatalog()
        let initial = try tabs()
        let target = try tabs(selection: "account")
        let store = try RouterStore(initialState: initial, configuration: .init(authorization: session.configuration()))
        expectRejection(await store.perform(.apply(.init(state: target))), .denied)
        #expect(store.state == initial)
        #expect(store.revision == 0)
        #expect(session.calls == 1)
        session.allowed = true
        guard case .applied = await store.perform(.apply(.init(state: target))) else {
            Issue.record("Current authorization must allow the selected tab")
            return
        }
        #expect(store.state == target)
        #expect(store.revision == 1)
        #expect(target.authorizationRoutes.isEmpty)
    }

    @Test("Unresolved plan-only selected roots fail closed even when no stored route is protected")
    func unknownRootFailsClosed() async throws {
        let session = Session()
        let target = RouterPlan(state: try tabs(selection: "account"))
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration()))
        expectRejection(await store.perform(.apply(target)), .unresolvedRoot)
        #expect(session.calls == 0)
        #expect(store.revision == 0)
        let link = RouterLinkPipeline<R>(
            originPolicy: .trustedInProcess,
            customResolver: { _ in target },
            authenticationPolicy: .configured(session.configuration())
        )
        #expect(await link.decide(for: url) == .rejected(reason: .authorization(.init(code: .unresolvedRoot))))
    }

    @Test("Inactive stored routes remain targets but an inactive catalog-only root does not")
    func storedVersusCatalogOnly() async throws {
        let session = Session()
        session.catalog = tabCatalog()
        let clean = try tabs()
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration()))
        guard case .applied = await store.perform(.apply(.init(state: clean))) else {
            Issue.record("Inactive account catalog entry must not demand login")
            return
        }
        #expect(session.calls == 0)
        expectRejection(await store.perform(.apply(.init(state: try tabs(storedSecret: true)))), .denied)
        #expect(session.calls == 1)
        #expect(store.state == clean)
        #expect(store.revision == 1)
    }

    @Test("Original matched intent is preserved through a custom planner and parsed once")
    func originalIntentUnion() async throws {
        let session = Session()
        let matches = AuthorizationCounter()
        let target = RouterPlan<R>(state: .rootStack(path: [.home]))
        let link = pipeline(target: target, matches: matches)
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration()))
        guard case .pending(let pending) = await store.handle(url, using: link) else {
            Issue.record("Protected match removed by custom planner must remain pending")
            return
        }
        #expect(pending.matchedRoute == .account)
        #expect(pending.plan == target)
        #expect(matches.value == 1)
        #expect(store.revision == 0)
        #expect(store.state == .rootStack)
    }

    @Test("Protected split roots and materialized scene roots cannot bypass Store authorization")
    func splitAndScene() async throws {
        let session = Session()
        session.catalog = .init(roots: [
            .init(style: .split, branch: "sidebar"): .home,
            .init(style: .split, branch: "detail"): .account
        ])
        let split = RouterPlan<R>(state: try .init(root: .container(.init(
            style: .split, branches: [.init(id: "sidebar"), .init(id: "detail")],
            split: .init()
        ))))
        let scene = RouterPlan<R>(state: try .init(windows: [.init(route: .scene)]))
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration()))
        expectRejection(await store.perform(.apply(split)), .denied)
        expectRejection(await store.perform(.apply(scene)), .denied)
        #expect(store.revision == 0)
        #expect(session.calls == 2)
    }

    @Test("Logout during asynchronous authorization rejects before policy or commit")
    func logoutDuringAuthorization() async throws {
        let session = Session()
        session.allowed = true
        let gate = AuthorizationGate()
        session.gate = gate
        var policyCalls = 0
        let store = try RouterStore<R>(configuration: .init(
            policies: [.init(name: "later") { _ in policyCalls += 1; return .allow }],
            authorization: session.configuration()
        ))
        let request = store.dispatch(.push(.account))
        await gate.waitUntilEntered()
        session.generation += 1
        session.allowed = false
        gate.release()
        expectRejection(await request.value, .generationChanged)
        #expect(policyCalls == 0)
        #expect(store.revision == 0)
    }

    @Test("Account change during policy invalidates an earlier successful authorization")
    func accountChangeDuringPolicy() async throws {
        let session = Session()
        session.allowed = true
        let gate = AuthorizationGate()
        let store = try RouterStore<R>(configuration: .init(
            policies: [.init(name: "approval") { _ in await gate.wait(); return .allow }],
            authorization: session.configuration()
        ))
        let request = store.dispatch(.push(.account))
        await gate.waitUntilEntered()
        session.generation += 1
        gate.release()
        expectRejection(await request.value, .generationChanged)
        #expect(store.revision == 0)
        #expect(store.state == .rootStack)
    }

    @Test("A queued old-account request cannot acquire the new account's generation")
    func queuedGeneration() async throws {
        let session = Session()
        session.allowed = true
        let gate = AuthorizationGate()
        var first = true
        let store = try RouterStore<R>(configuration: .init(
            policies: [.init(name: "queue blocker") { _ in
                if first { first = false; await gate.wait() }
                return .allow
            }], authorization: session.configuration()
        ))
        let blocker = store.dispatch(.push(.home))
        await gate.waitUntilEntered()
        let queued = store.dispatch(.push(.account))
        while store.queuedRequests.isEmpty { await Task.yield() }
        session.generation += 1
        gate.release()
        expectRejection(await blocker.value, .generationChanged)
        expectRejection(await queued.value, .generationChanged)
        #expect(session.calls == 0)
        #expect(store.revision == 0)
        guard case .applied = await store.perform(.push(.account)) else {
            Issue.record("A fresh request under the current generation must succeed")
            return
        }
        #expect(store.revision == 1)
    }

    @Test("Pending restart revalidates URL, catalog, original intent, and current authorization")
    func pendingRestart() async throws {
        let session = Session()
        session.catalog = tabCatalog()
        let oldTarget = RouterPlan(state: try tabs(selection: "account"))
        let matches = AuthorizationCounter()
        let oldPipeline = pipeline(configuration: session.configuration(), target: oldTarget, matches: matches)
        let store = RouterStore<R>()
        guard case .pending(let pending) = await store.handle(url, using: oldPipeline) else {
            Issue.record("Expected a pending login intent")
            return
        }
        let encoded = try JSONEncoder().encode(pending)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("generation"))
        #expect(!text.contains("authorize"))
        let restored = try JSONDecoder().decode(PendingRouterLink<R>.self, from: encoded)
        #expect(restored.isRevalidationRequired)
        guard case .completed(_, let unsafe) = await restored.resume(on: store) else {
            Issue.record("Missing current pipeline must reject")
            return
        }
        expectRejection(unsafe, .revalidationRequired)
        let missingAuth = pipeline(target: oldTarget)
        #expect(await restored.resume(on: store, using: missingAuth)
            == .rejected(url: url, reason: .authorization(.init(code: .revalidationRequired))))
        session.allowed = true
        session.generation += 1
        let changedPlan = RouterPlan<R>(state: .rootStack(path: [.detail]))
        let changedPipeline = pipeline(configuration: session.configuration(), target: changedPlan)
        #expect(await restored.resume(on: store, using: changedPipeline)
            == .rejected(url: url, reason: .authorization(.init(code: .intentChanged))))
        let changedRoute = pipeline(configuration: session.configuration(), target: oldTarget, matched: .home)
        #expect(await restored.resume(on: store, using: changedRoute)
            == .rejected(url: url, reason: .authorization(.init(code: .intentChanged))))
        session.catalog = .init()
        guard case .completed(_, let unknown) = await restored.resume(on: store, using: oldPipeline) else {
            Issue.record("A removed declaration must fail current catalog revalidation")
            return
        }
        expectRejection(unknown, .unresolvedRoot)
        session.catalog = tabCatalog()
        let newTarget = oldTarget
        let newPipeline = pipeline(configuration: session.configuration(), target: newTarget, matches: matches)
        guard case .completed(let used, .applied) = await restored.resume(on: store, using: newPipeline) else {
            Issue.record("Current pipeline must allow after login")
            return
        }
        #expect(used == newTarget)
        #expect(store.state == newTarget.state)
        #expect(store.revision == 1)
        #expect(matches.value == 3)
        let wrongOrigin = RouterLinkPipeline<R>(
            originPolicy: .allowlisted(schemes: ["https"], hosts: ["new.example"]),
            customResolver: { _ in newTarget }
        )
        guard case .rejected(_, .schemeNotAllowed) = await restored.resume(on: store, using: wrongOrigin) else {
            Issue.record("Stored intent must obey current origin policy")
            return
        }
        #expect(store.revision == 1)
    }

    @Test("Duplicate admitted intents commit at most one state revision")
    func duplicateIntent() async {
        let session = Session()
        session.allowed = true
        let target = RouterPlan<R>(state: .rootStack(path: [.account]))
        let link = pipeline(configuration: session.configuration(), target: target)
        let store = RouterStore<R>()
        guard case .completed(_, .applied) = await store.handle(url, using: link),
              case .completed(_, .unchanged) = await store.handle(url, using: link) else {
            Issue.record("Duplicate intent should resolve without a second commit")
            return
        }
        #expect(store.revision == 1)
        #expect(session.calls == 2)
    }

    @Test("Timed-out noncooperative authentication remains counted until actual exit")
    func timedOutAuthBudget() async throws {
        let gate = AuthorizationGate()
        let session = Session()
        session.gate = gate
        let sleeper = ManualRuntimeSleeper()
        var registrations = sleeper.registrations.makeAsyncIterator()
        var configuration = RouterStoreConfiguration<R>(
            authorization: session.configuration(), policyTimeout: .seconds(30),
            maximumActivePolicyOperationCount: 1
        )
        configuration.runtimeDependencies.sleep = { try await sleeper.sleep(for: $0) }
        let store = try RouterStore<R>(configuration: configuration)
        let request = store.dispatch(.push(.account))
        await gate.waitUntilEntered()
        #expect(await registrations.next() == .seconds(30))
        await sleeper.resumeAll()
        expectRejection(await request.value, .timedOut)
        #expect(store.policyOperations.activeCount == 1)
        for _ in 0..<1_000 {
            expectRejection(await store.perform(.push(.account)), .capacityExceeded)
        }
        #expect(session.calls == 1)
        #expect(store.policyOperations.activeCount == 1)
        #expect(store.activeAuthorizationRaces.isEmpty)
        #expect(store.revision == 0)
        gate.release()
        await gate.waitUntilExited()
        #expect(store.policyOperations.activeCount == 0)
        #expect(store.revision == 0)
        #expect(store.state == .rootStack)
        session.gate = nil
        session.allowed = true
        guard case .applied = await store.perform(.push(.account)) else {
            Issue.record("Actual exit must release authorization capacity")
            return
        }
        #expect(store.policyOperations.activeCount == 0)
    }

    @Test("Snapshot restoration and policy bypass do not confer authorization")
    func restorationAndBypass() async throws {
        let session = Session()
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let protected = RouterState<R>.rootStack(path: [.account])
        let data = try codec.encode(protected)
        let store = try RouterStore<R>(configuration: .init(authorization: session.configuration()))
        expectRejection(try await store.restore(from: data, using: codec), .denied)
        expectRejection(await store.perform(
            .apply(.init(state: protected)), context: .init(),
            expectedRevision: nil, bypassesPolicies: true
        ), .denied)
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Policy deferral preserves the submitted generation across explicit continuation")
    func policyDeferralGeneration() async throws {
        let session = Session()
        session.allowed = true
        let id = RouterDeferralID()
        let store = try RouterStore<R>(configuration: .init(
            policies: [.init(name: "approval") { _ in .deferRequest(id) }],
            authorization: session.configuration()
        ))
        guard case .deferred = await store.perform(.push(.account)) else {
            Issue.record("Expected policy deferral after current authorization")
            return
        }
        session.generation += 1
        expectRejection(await store.resumeDeferred(id), .generationChanged)
        #expect(store.deferredTransitions.isEmpty)
        #expect(session.calls == 1)
        #expect(store.revision == 0)
    }

    @Test("Cancelling authorization releases its waiter but retains the live operation")
    func cancellationAndLateAuth() async throws {
        let session = Session()
        let gate = AuthorizationGate()
        session.gate = gate
        var terminalCount = 0
        let store = try RouterStore<R>(configuration: .init(
            authorization: session.configuration(), maximumActivePolicyOperationCount: 1,
            onEvent: { event in
                if case .rejected = event { terminalCount += 1 }
            }
        ))
        let request = store.dispatch(.push(.account))
        await gate.waitUntilEntered()
        request.cancel()
        guard case .rejected(_, _, _, .cancelled) = await request.value else {
            Issue.record("Expected one cancellation terminal")
            gate.release()
            return
        }
        #expect(terminalCount == 1)
        #expect(store.policyOperations.activeCount == 1)
        gate.release()
        await gate.waitUntilExited()
        #expect(store.policyOperations.activeCount == 0)
        #expect(terminalCount == 1)
        #expect(store.revision == 0)
        #expect(store.state == .rootStack)
    }

    @Test("One thousand cooperative authorization callbacks return every registry slot")
    func cooperativeAuthCleanup() async throws {
        let session = Session()
        session.allowed = true
        let store = try RouterStore<R>(configuration: .init(
            authorization: session.configuration(), maximumActivePolicyOperationCount: 1
        ))
        for index in 0..<1_000 {
            let route: R = index.isMultiple(of: 2) ? .account : .storedSecret
            guard case .applied = await store.perform(.replaceStack([route])) else {
                Issue.record("A completed authorization must release its slot before the next request")
                return
            }
            #expect(store.policyOperations.activeCount == 0)
            #expect(store.activeAuthorizationRaces.isEmpty)
        }
        #expect(session.calls == 1_000)
        #expect(store.revision == 1_000)
    }

    @Test("Removal-only native failure repair cannot preserve a failed scene after logout")
    func removalOnlySystemRepair() async throws {
        let session = Session()
        let window = RouterWindow<R>(route: .scene)
        let initial = try RouterState<R>(root: .stack(path: [.account]), windows: [window])
        let store = try RouterStore(initialState: initial, configuration: .init(authorization: session.configuration()))
        expectRejection(await store.perform(.dismissWindow(window.id)), .denied)
        session.generation += 1
        guard case .applied = await store.reconcileSceneSystemFailure(.dismissWindow(window.id)) else {
            Issue.record("A failed native window must be removable without new authorization")
            return
        }
        #expect(store.state.windows.isEmpty)
        #expect(store.state.root == initial.root)
        #expect(store.revision == 1)
        #expect(session.calls == 1)
    }

    @Test("A queued removal-only native repair survives a later account change")
    func queuedSystemRepairSurvivesLogout() async throws {
        let session = Session()
        session.allowed = true
        let gate = AuthorizationGate()
        let window = RouterWindow<R>(route: .scene)
        let initial = try RouterState<R>(root: .stack(path: [.account]), windows: [window])
        let store = try RouterStore(initialState: initial, configuration: .init(
            policies: [.init(name: "block") { _ in await gate.wait(); return .allow }],
            authorization: session.configuration()
        ))
        let blocker = store.dispatch(.push(.home))
        await gate.waitUntilEntered()
        let repair = Task { await store.reconcileSceneSystemFailure(.dismissWindow(window.id)) }
        while store.queuedSystemRepairs.isEmpty { await Task.yield() }
        session.generation += 1
        session.allowed = false
        gate.release()
        expectRejection(await blocker.value, .generationChanged)
        guard case .applied = await repair.value else {
            Issue.record("The Store-owned removal-only repair must not keep the failed scene")
            return
        }
        #expect(store.state.windows.isEmpty)
        #expect(store.state.root == initial.root)
        #expect(store.revision == 1)
    }

    @Test("Pending intent checks reject surface changes but allow fresh instance IDs")
    func pendingSurfaceAndInstanceIdentity() async throws {
        let oldWindow = RouterPlan<R>(state: try .init(windows: [.init(route: .account)]))
        let newWindow = RouterPlan<R>(state: try .init(windows: [.init(route: .account)]))
        let pending = PendingRouterLink(url: url, gatedRoute: .account, plan: oldWindow, matchedRoute: .account, isRevalidationRequired: true)
        #expect(pending.matchesIntent(of: .init(plan: newWindow, matchedRoute: .account)))
        let movedToStack = RouterPlan<R>(state: .rootStack(path: [.account]))
        #expect(!pending.matchesIntent(of: .init(plan: movedToStack, matchedRoute: .account)))
        let oldPresentation = RouterPlan<R>(state: try .init(root: .stack(.init(
            presentation: .init(route: .account, style: .sheet)
        ))))
        let newPresentation = RouterPlan<R>(state: try .init(root: .stack(.init(
            presentation: .init(route: .account, style: .sheet)
        ))))
        let modal = PendingRouterLink(url: url, gatedRoute: .account, plan: oldPresentation, matchedRoute: .account, isRevalidationRequired: true)
        #expect(modal.matchesIntent(of: .init(plan: newPresentation, matchedRoute: .account)))
        #expect(!modal.matchesIntent(of: .init(plan: newWindow, matchedRoute: .account)))
    }

    @Test("A denied Store link inspects each duplicate target once")
    func deniedIntentInspectedOnce() async {
        let inspections = AuthorizationCounter()
        let authorization = RouterAuthorizationConfiguration<R>(
            requiresAuthorization: { _ in inspections.increment(); return true },
            authorize: { false }
        )
        let target = RouterPlan<R>(state: .rootStack(path: [.account]))
        let store = RouterStore<R>()
        guard case .pending = await store.handle(url, using: pipeline(configuration: authorization, target: target)) else {
            Issue.record("Expected pending protected intent")
            return
        }
        #expect(inspections.value == 1)
        #expect(store.revision == 0)
    }

    @Test("Legacy pending data cannot lose a protected route absent from its planned state")
    func legacyPendingRetainsGatedIntent() async throws {
        let session = Session()
        let target = RouterPlan<R>(state: .rootStack(path: [.home]))
        let legacy = PendingRouterLink(url: url, gatedRoute: .account, plan: target)
        let restored = try JSONDecoder().decode(PendingRouterLink<R>.self, from: JSONEncoder().encode(legacy))
        let current = pipeline(configuration: session.configuration(), target: target, matched: .home)
        let store = RouterStore<R>()
        guard case .pending(let retained) = await restored.resume(on: store, using: current) else {
            Issue.record("A retained protected route must still be checked when legacy original-match metadata is absent")
            return
        }
        #expect(retained.gatedRoute == .account)
        #expect(session.calls == 1)
        #expect(store.revision == 0)
    }

    @Test("No authorization configuration keeps ordinary navigation and unknown catalogs unchanged")
    func noAuthControl() async throws {
        let target = try tabs(selection: "account")
        let store = RouterStore<R>()
        guard case .applied = await store.perform(.apply(.init(state: target))) else {
            Issue.record("No-auth applications do not need a new catalog adapter")
            return
        }
        #expect(store.state == target)
        #expect(store.revision == 1)
    }
}

@MainActor
private final class AuthorizationGate {
    private var entered = false
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        exited = true
        for waiter in exitWaiters { waiter.resume() }
        exitWaiters.removeAll()
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() { continuation?.resume(); continuation = nil }

    func waitUntilExited() async {
        if !exited { await withCheckedContinuation { exitWaiters.append($0) } }
        await Task.yield()
    }
}

private final class AuthorizationCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}
