import Foundation
import Testing
import InnoRouter
@testable import InnoRouterSwiftUI

private enum AttributedRoute: Route { case original, replacement }

@MainActor
private final class AttributedGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        await withCheckedContinuation {
            waiter = $0
            entered = true
            let pending = observers; observers.removeAll()
            pending.forEach { $0.resume() }
        }
    }
    func nextEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { let pending = waiter; waiter = nil; pending?.resume() }
}

// This same event/Store contract compiles at b2ae2617 with ROUTER_BASELINE_CONTRACT.
// At that SHA the callback has no bound payload. The only changed adapter in
// the fixed run is the approved native value transport; assertions stay fixed.
@Suite("Attributed native canonical contract", .timeLimit(.minutes(1)))
@MainActor
struct ImmersiveAttributedContractTests {
    enum Order: CaseIterable { case before, after }

    @Test("Both callback orders preserve canonical scene with monotonic commits", arguments: Order.allCases)
    func canonicalContract(_ order: Order) async throws {
        let initial = try RouterState<AttributedRoute>(immersiveSpace: .init(id: "shared", route: .original))
        let gate = AttributedGate()
        var revisions: [UInt64] = []
        let store = try RouterStore(initialState: initial, configuration: .init(policies: [RouterPolicy(name: "unrelated") { transition in
            if transition.action == .push(.original) { await gate.enter() }
            return .allow
        }], onEvent: { event in
            if case .committed(_, _, _, let revision, _) = event { revisions.append(revision) }
        }))
        let oldToken = try #require(store.immersiveSpaceLifecycleToken)
        let oldScope = store.scope(at: .immersiveSpace("shared"))
        let oldPrecondition = try #require(oldScope.combinedExecutionPrecondition(nil))
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: oldToken))
#if !ROUTER_BASELINE_CONTRACT
        var activation: RouterImmersiveActivation?
        store.sceneRestorationRegistry.declareAttributedImmersiveSpace(id: "shared")
        store.sceneRestorationRegistry.installImmersiveActions(.init(open: { _ in Issue.record("attributed scene used id-only open"); return .error }, dismiss: {}, openActivation: { value in activation = value; return .error }), owner: UUID())
#endif
        var requests = store.requestObservations.makeAsyncIterator()
        let unrelated = Task { @MainActor in await store.perform(.push(.original)) }
        _ = await requests.next()
        await gate.nextEntry()
        let restore = Task { @MainActor in await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: oldToken, ticket: ticket, store: store, open: { .error }, dismiss: {}) }
        _ = await requests.next()
        #expect(store.revision == 0)
        if order == .before {
#if !ROUTER_BASELINE_CONTRACT
            #expect(await store.admitAttributedImmersiveAppearance(try #require(activation)))
#else
            #expect(admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: oldToken, store: store, executionPrecondition: oldPrecondition))
#endif
        }
        gate.release()
        _ = await unrelated.value
        #expect(await restore.value == false)
        if order == .after {
            #expect(store.state.immersiveSpace == nil)
            #expect(store.revision == 2)
            print("ATTRIBUTED_REPAIR canonical=false revision=2")
#if !ROUTER_BASELINE_CONTRACT
            #expect(await store.admitAttributedImmersiveAppearance(try #require(activation)))
#else
            _ = admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: store.immersiveSpaceLifecycleToken, store: store, executionPrecondition: store.scope(at: .immersiveSpace("shared")).combinedExecutionPrecondition(nil))
#endif
        }
        #expect(store.state.immersiveSpace == initial.immersiveSpace, "Actual native appearance must agree with the original canonical scene")
        #expect(store.state.root == .stack(path: [.original]), "Unrelated committed navigation must survive recovery")
        #expect(store.revision == (order == .before ? 1 : 3))
        #expect(revisions == (order == .before ? [1] : [1, 2, 3]))
        #expect((oldPrecondition(store.state) != nil) == (order == .after), "Recovery issues new scope authority; an expired scope never revives")
        let currentScope = store.scope(at: .immersiveSpace("shared"))
        let currentPrecondition = try #require(currentScope.combinedExecutionPrecondition(nil))
        #expect(currentPrecondition(store.state) == nil)
        #expect((store.immersiveSpaceLifecycleToken == oldToken) == (order == .before))
#if !ROUTER_BASELINE_CONTRACT
        let revision = store.revision
        #expect(await store.admitAttributedImmersiveAppearance(try #require(activation)))
        #expect(store.revision == revision, "Repeated callback cannot add another commit or native open")
#endif
    }
}

#if !ROUTER_BASELINE_CONTRACT
@MainActor
private final class AttributedNativeBox {
    var activation: RouterImmersiveActivation?
    var opens = 0
    var idOnlyOpens = 0
    var dismissals = 0
}

@MainActor
private struct AttributedFixture {
    let store: RouterStore<AttributedRoute>
    let box = AttributedNativeBox()
    let owner = UUID()
    let token: UUID
    let ticket: UUID

    init(configuration: RouterStoreConfiguration<AttributedRoute> = .init(), open: (@MainActor () async -> RouterImmersiveSpaceOpenResult)? = nil) throws {
        store = try RouterStore(initialState: RouterState<AttributedRoute>(immersiveSpace: .init(id: "shared", route: .original)), configuration: configuration)
        token = try #require(store.immersiveSpaceLifecycleToken)
        ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        store.sceneRestorationRegistry.declareAttributedImmersiveSpace(id: "shared")
        let box = box
        store.sceneRestorationRegistry.installImmersiveActions(.init(open: { _ in box.idOnlyOpens += 1; return .error }, dismiss: { box.dismissals += 1 }, openActivation: { value in box.activation = value; box.opens += 1; return await open?() ?? .error }), owner: owner)
    }

    func fail(deferredClose: RouterDeferralID? = nil) async -> Bool {
        await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { .error }, dismiss: {}, deferredClose: deferredClose)
    }
    func appearance() async throws -> Bool {
        await store.admitAttributedImmersiveAppearance(try #require(box.activation))
    }
}

@Suite("Attributed native discriminating controls", .timeLimit(.minutes(1)))
@MainActor
struct ImmersiveAttributedControlTests {
    @Test("Revocation between appearance claim and effect entry still performs owned cleanup")
    func authorityRevokedAfterClaim() async throws {
        var generation: UInt64 = 0
        let fixture = try AttributedFixture(configuration: .init(authorization: .init(generation: { generation }, requiresAuthorization: { _ in true }, authorize: { true })))
        _ = await fixture.fail()
        let activation = try #require(fixture.box.activation)
        #expect(await fixture.store.admitAttributedImmersiveAppearance(activation, onRecoveryClaim: { generation += 1 }) == false)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
        #expect(fixture.box.dismissals == 1)
        #expect(await fixture.store.admitAttributedImmersiveAppearance(activation) == false)
    }

    @Test("A disappearance while recovery awaits authorization prevents a new scene commit")
    func nativeClosesDuringAuthorization() async throws {
        let gate = AttributedGate()
        let fixture = try AttributedFixture(configuration: .init(authorization: .init(requiresAuthorization: { _ in true }, authorize: { await gate.enter(); return true })))
        _ = await fixture.fail()
        let task = Task { @MainActor in try await fixture.appearance() }
        await gate.nextEntry()
        let activation = try #require(fixture.box.activation)
        #expect(fixture.store.attributedImmersiveDisappearance(activation) == nil)
        gate.release()
        #expect(try await task.value == false)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
        #expect(fixture.box.dismissals == 0)
    }

    @Test("A later restoration attempt cannot borrow an earlier close's continuation", arguments: [RouterDeferralResumeStrategy.requireUnchangedState, .rebaseOnCurrentState])
    func deferralReentry(_ strategy: RouterDeferralResumeStrategy) async throws {
        let id = RouterDeferralID()
        var result = RouterImmersiveSpaceOpenResult.opened
        let fixture = try AttributedFixture(configuration: .init(policies: [RouterPolicy(name: "hold") { transition in transition.action == .dismissImmersiveSpace ? .deferRequest(id) : .allow }]), open: { result })
        _ = await synchronizeRouterImmersiveSpaceDisappearance(id: "shared", lifecycleToken: fixture.token, store: fixture.store)
        #expect(await fixture.fail(deferredClose: id))
        #expect(try await fixture.appearance())
        let previous = try #require(fixture.box.activation)
        #expect(fixture.store.attributedImmersiveDisappearance(previous) == fixture.token)
        let reentry = try #require(await synchronizeRouterImmersiveSpaceDisappearance(id: "shared", lifecycleToken: fixture.token, store: fixture.store))
        guard case .rejected = reentry else { Issue.record("Expected duplicate deferral rejection"); return }
        let ticket = try #require(fixture.store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: fixture.token))
        result = .error
        _ = await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: fixture.token, ticket: ticket, store: fixture.store, open: { .error }, dismiss: {})
        #expect(try await fixture.appearance())
        #expect(await fixture.store.admitAttributedImmersiveAppearance(previous) == false)
        let current = fixture.store.state
        let resolution = await fixture.store.resolveDeferred(id, with: .allow, resumeStrategy: strategy)
        guard case .rejected = resolution else { Issue.record("Older continuation acquired a different attempt's fresh scope"); return }
        #expect(fixture.store.state == current)
        #expect(fixture.store.revision == 2)
        #expect(fixture.box.opens == 2)
    }

    @Test("An unrelated whole-state plan preserves the live native binding")
    func retainedScenePlan() async throws {
        let fixture = try AttributedFixture(open: { .opened })
        #expect(await fixture.fail())
        #expect(try await fixture.appearance())
        let plan = RouterPlan(state: try RouterState<AttributedRoute>(root: .stack(path: [.replacement]), immersiveSpace: fixture.store.state.immersiveSpace))
        _ = await fixture.store.perform(.apply(plan))
        #expect(fixture.store.hasAdoptedImmersiveAppearance(id: "shared", lifetime: fixture.token))
        let activation = try #require(fixture.box.activation)
        #expect(fixture.store.attributedImmersiveDisappearance(activation) == fixture.token)
        _ = await synchronizeRouterImmersiveSpaceDisappearance(id: "shared", lifecycleToken: fixture.token, store: fixture.store)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 2)
    }

    @Test("Immediate close after recovery retains a matching native dismissal effect")
    func immediateCloseAfterRecovery() async throws {
        let fixture = try AttributedFixture()
        _ = await fixture.fail()
        #expect(try await fixture.appearance())
        let activation = try #require(fixture.box.activation)
        _ = await fixture.store.perform(.immersiveSpaceScoped("shared", .push(.replacement)))
        let latestScene = fixture.store.state.immersiveSpace
        _ = await fixture.store.perform(.dismissImmersiveSpace)
        #expect(fixture.store.state.immersiveSpace == nil)
        let pending = try #require(fixture.store.pendingImmersiveDismissal)
        #expect(pending.activation == activation)
        #expect(pending.scene == latestScene, "Native close event must retain the latest accepted scene history")
        #expect(fixture.store.immersiveDismissalEpoch == pending.id)
        #expect(try await fixture.appearance() == false)
        fixture.store.finishAttributedImmersiveDismissal(UUID())
        #expect(fixture.store.pendingImmersiveDismissal?.id == pending.id)
        fixture.store.finishAttributedImmersiveDismissal(pending.id)
        #expect(fixture.store.pendingImmersiveDismissal == nil)
        #expect(fixture.store.immersiveDismissalEpoch == nil)
    }

    @Test("Another same-owner attempt revokes every obsolete native result", arguments: [RouterImmersiveSpaceOpenResult.opened, .error, .userCancelled])
    func newerAttemptDuringOpen(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let gate = AttributedGate()
        let fixture = try AttributedFixture(open: { await gate.enter(); return result })
        let task = Task { @MainActor in await fixture.fail() }
        await gate.nextEntry()
        let old = try #require(fixture.box.activation)
        let next = try #require(fixture.store.beginAttributedImmersiveOpen(id: "shared", lifecycleToken: fixture.token, owner: fixture.owner))
        gate.release()
        #expect(await task.value == false)
        #expect(await fixture.store.admitAttributedImmersiveAppearance(old) == false)
        #expect(await fixture.store.admitAttributedImmersiveAppearance(next))
        #expect(fixture.store.state.immersiveSpace?.route == .original)
        #expect(fixture.store.revision == 0)
        #expect(fixture.box.dismissals == (result == .opened ? 1 : 0))
    }

    @Test("Matching bound appearance before native return protects every result", arguments: [RouterImmersiveSpaceOpenResult.opened, .error, .userCancelled])
    func appearanceBeforeReturn(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let gate = AttributedGate()
        let fixture = try AttributedFixture(open: { await gate.enter(); return result })
        let task = Task { @MainActor in await fixture.fail() }
        await gate.nextEntry()
        #expect(try await fixture.appearance())
        gate.release()
        #expect(await task.value == (result == .opened))
        #expect(fixture.store.state.immersiveSpace?.route == .original)
        #expect(fixture.store.revision == 0)
        #expect(fixture.box.dismissals == 0)
    }

    @Test("An obsolete attributed driver result cannot delete surviving canonical authority", arguments: [RouterImmersiveSpaceOpenResult.opened, .error, .userCancelled])
    func driverChangesDuringOpen(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let gate = AttributedGate()
        let fixture = try AttributedFixture(open: { await gate.enter(); return result })
        let task = Task { @MainActor in await fixture.fail() }
        await gate.nextEntry()
        let successor = UUID()
        var successorDismissals = 0
        fixture.store.sceneRestorationRegistry.installImmersiveActions(.init(open: { _ in .opened }, dismiss: { successorDismissals += 1 }), owner: successor)
        gate.release()
        #expect(await task.value == false)
        #expect(fixture.store.state.immersiveSpace?.route == .original)
        #expect(fixture.store.revision == 0)
        #expect(fixture.box.dismissals == (result == .opened ? 1 : 0))
        #expect(successorDismissals == 0)
        #expect(try await fixture.appearance() == false)
    }

    @Test("An attributed effect cancelled before starting opens nothing and caller releases its ticket")
    func cancelledBeforeStarting() async throws {
        let gate = AttributedGate()
        let blocker = Task { @MainActor in await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue { await gate.enter(); return true } }
        await gate.nextEntry()
        let fixture = try AttributedFixture()
        let task = Task { @MainActor in
            defer { fixture.store.sceneRestorationRegistry.finishImmersiveSpaceRestoration(id: "shared", lifecycleToken: fixture.token, ticket: fixture.ticket) }
            return await fixture.fail()
        }
        task.cancel()
        gate.release()
        _ = await blocker.value
        #expect(await task.value == false)
        #expect(fixture.box.opens == 0 && fixture.box.activation == nil)
        #expect(fixture.store.state.immersiveSpace?.route == .original)
        #expect(fixture.store.revision == 0)
        #expect(!fixture.store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(id: "shared", lifecycleToken: fixture.token, ticket: fixture.ticket))
    }

    @Test("Cancelling a view waiter cannot cancel a Store-owned recovery already awaiting authorization")
    func cancelledRecoveryWaiter() async throws {
        let gate = AttributedGate()
        let fixture = try AttributedFixture(configuration: .init(authorization: .init(requiresAuthorization: { _ in true }, authorize: { await gate.enter(); return true })))
        _ = await fixture.fail()
        let task = Task { @MainActor in try await fixture.appearance() }
        await gate.nextEntry()
        task.cancel()
        gate.release()
        #expect(try await task.value)
        #expect(fixture.store.state.immersiveSpace?.route == .original)
        #expect(fixture.store.revision == 2)
        #expect(fixture.box.opens == 1 && fixture.box.dismissals == 0)
    }

    @Test("Genuine failure and native cancellation finish cleanup without appearance", arguments: [RouterImmersiveSpaceOpenResult.error, .userCancelled])
    func noAppearance(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let fixture = try AttributedFixture(open: { result })
        #expect(await fixture.fail() == false)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
        #expect(fixture.box.opens == 1 && fixture.box.idOnlyOpens == 0)
        #expect(!fixture.store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(id: "shared", lifecycleToken: fixture.token, ticket: fixture.ticket))
        if result == .userCancelled {
            #expect(try await fixture.appearance() == false)
            #expect(fixture.store.state.immersiveSpace == nil)
            #expect(fixture.store.revision == 1)
        }
    }

    @Test("Accepted unchanged close revokes a late appearance after failure cleanup")
    func explicitClose() async throws {
        let fixture = try AttributedFixture()
        _ = await fixture.fail()
        guard case .unchanged = await fixture.store.perform(.dismissImmersiveSpace) else { Issue.record("expected accepted unchanged explicit close"); return }
        #expect(try await fixture.appearance() == false)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
    }

    @Test("Same-ID replacement, unrelated values and another Store cannot borrow a failed attempt")
    func differentLifetime() async throws {
        let fixture = try AttributedFixture(), other = try AttributedFixture()
        _ = await fixture.fail()
        _ = await other.fail()
        let old = try #require(fixture.box.activation)
        #expect(!fixture.store.canRenderAttributedImmersiveSpace(old))
        #expect(await other.store.admitAttributedImmersiveAppearance(old) == false)
        let foreignRequest = RouterImmersiveActivation(storeID: old.storeID, sceneID: old.sceneID, lifetime: old.lifetime, requestID: UUID(), driverOwner: old.driverOwner)
        #expect(await fixture.store.admitAttributedImmersiveAppearance(foreignRequest) == false)
        _ = await fixture.store.perform(.enterImmersiveSpace(.init(id: "shared", route: .replacement)))
        let replacementToken = try #require(fixture.store.immersiveSpaceLifecycleToken)
        #expect(try await fixture.appearance() == false)
        #expect(!fixture.store.canRenderAttributedImmersiveSpace(old), "An expired native host cannot render the replacement scope")
        #expect(fixture.store.immersiveSpaceLifecycleToken == replacementToken)
        #expect(replacementToken != fixture.token)
        #expect(fixture.store.state.immersiveSpace?.route == .replacement)
        #expect(fixture.store.revision == 2)
    }

    @Test("Replacement driver and obsolete owner removal cannot transfer attempt authority")
    func replacementDriver() async throws {
        let fixture = try AttributedFixture()
        _ = await fixture.fail()
        let second = UUID()
        fixture.store.sceneRestorationRegistry.installImmersiveActions(.init(open: { _ in .opened }, dismiss: {}), owner: second)
        fixture.store.sceneRestorationRegistry.removeImmersiveActions(owner: fixture.owner)
        #expect(try await fixture.appearance() == false)
        #expect(fixture.store.sceneRestorationRegistry.immersiveActionsOwner == second)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
    }

    @Test("Recovery rechecks app authorization instead of borrowing removal-only repair privilege")
    func authorizationDenied() async throws {
        var allowed = true
        let fixture = try AttributedFixture(configuration: .init(authorization: .init(requiresAuthorization: { _ in true }, authorize: { allowed })))
        _ = await fixture.fail()
        allowed = false
        #expect(try await fixture.appearance() == false)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
        #expect(fixture.box.dismissals == 1)
        allowed = true
        #expect(try await fixture.appearance() == false)
        #expect(fixture.store.revision == 1)
    }

    @Test("Authority generation changes reject a matching transport value")
    func generationChanged() async throws {
        var generation: UInt64 = 0
        let fixture = try AttributedFixture(configuration: .init(authorization: .init(generation: { generation }, requiresAuthorization: { _ in true }, authorize: { true })))
        _ = await fixture.fail()
        generation += 1
        #expect(try await fixture.appearance() == false)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
    }

    @Test("Only the originating system-close deferral follows its attributed recovery", arguments: ["allow", "reject", "cancel"])
    func deferralContinuity(_ resolution: String) async throws {
        let id = RouterDeferralID()
        let fixture = try AttributedFixture(configuration: .init(policies: [RouterPolicy(name: "hold") { transition in
            transition.action == .dismissImmersiveSpace ? .deferRequest(id) : .allow
        }]))
        let close = try #require(await synchronizeRouterImmersiveSpaceDisappearance(id: "shared", lifecycleToken: fixture.token, store: fixture.store))
        guard case .deferred = close else { Issue.record("expected actual system deferral"); return }
        _ = await fixture.fail(deferredClose: id)
        #expect(fixture.store.revision == 1)
        #expect(try await fixture.appearance())
        #expect(fixture.store.revision == 2)
        let result: RouterOutcome<AttributedRoute>
        if resolution == "allow" { result = await fixture.store.resolveDeferred(id, with: .allow) }
        else if resolution == "reject" { result = await fixture.store.resolveDeferred(id, with: .reject("keep")) }
        else { result = await fixture.store.cancelDeferred(id) }
        if resolution == "allow" {
            guard case .applied = result else { Issue.record("same attributed close did not resume: \(result)"); return }
            #expect(fixture.store.state.immersiveSpace == nil)
            #expect(fixture.store.revision == 3)
        } else {
            #expect(fixture.store.state.immersiveSpace?.route == .original)
            #expect(fixture.store.revision == 2)
        }
        #expect(fixture.box.opens == 1 && fixture.box.idOnlyOpens == 0)
    }

    @Test("An unrelated commit still makes default deferral resume stale")
    func unrelatedRevision() async throws {
        let id = RouterDeferralID()
        let fixture = try AttributedFixture(configuration: .init(policies: [RouterPolicy(name: "hold") { transition in transition.action == .dismissImmersiveSpace ? .deferRequest(id) : .allow }]))
        _ = await synchronizeRouterImmersiveSpaceDisappearance(id: "shared", lifecycleToken: fixture.token, store: fixture.store)
        _ = await fixture.fail(deferredClose: id)
        #expect(try await fixture.appearance())
        _ = await fixture.store.perform(.push(.original))
        let before = fixture.store.state
        let result = await fixture.store.resolveDeferred(id, with: .allow)
        guard case .rejected = result else { Issue.record("unrelated revision was silently ignored"); return }
        #expect(fixture.store.state == before)
        #expect(fixture.store.revision == 3)
    }

    @Test("Cancelling the caller after native open starts cannot abandon failure cleanup")
    func callerCancellation() async throws {
        let gate = AttributedGate()
        let fixture = try AttributedFixture(open: { await gate.enter(); return .error })
        let task = Task { @MainActor in await fixture.fail() }
        await gate.nextEntry()
        task.cancel()
        gate.release()
        #expect(await task.value == false)
        #expect(fixture.store.state.immersiveSpace == nil)
        #expect(fixture.store.revision == 1)
        #expect(try await fixture.appearance())
        #expect(fixture.store.state.immersiveSpace?.route == .original)
        #expect(fixture.store.revision == 2)
    }
}
#endif
