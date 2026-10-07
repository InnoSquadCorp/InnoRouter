import Foundation
import Testing
import InnoRouter
@testable import InnoRouterSwiftUI

private enum LateAppearanceRoute: Route { case original, replacement }

@MainActor
private final class LateAppearanceGate {
    private var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        await withCheckedContinuation {
            waiting = $0
            entered = true
            let pending = observers
            observers.removeAll()
            pending.forEach { $0.resume() }
        }
    }
    func nextEntry() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { let pending = waiting; waiting = nil; pending?.resume() }
}

@Suite("Native repair discriminating controls", .timeLimit(.minutes(1)))
@MainActor
struct ImmersiveRepairControlTests {
    @Test("No native appearance repairs an actual error or user cancellation", arguments: [RouterImmersiveSpaceOpenResult.error, .userCancelled])
    func actualFailure(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let store = try RouterStore(initialState: RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original)))
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        #expect(await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { result }, dismiss: {}) == false)
        #expect(store.state.immersiveSpace == nil)
        #expect(store.revision == 1)
    }

    @Test("Explicit close and same-ID reentry reject old appearance and old open result", arguments: [RouterImmersiveSpaceOpenResult.opened, .error, .userCancelled])
    func replacement(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let store = try RouterStore(initialState: RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original)))
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let precondition = store.scope(at: .immersiveSpace("shared")).combinedExecutionPrecondition(nil)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        let gate = LateAppearanceGate()
        var dismissals = 0
        let restoring = Task { @MainActor in
            await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { await gate.enter(); return result }, dismiss: { dismissals += 1 })
        }
        await gate.nextEntry()
        _ = await store.perform(.dismissImmersiveSpace)
        #expect(!admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: token, store: store, executionPrecondition: precondition))
        _ = await store.perform(.enterImmersiveSpace(.init(id: "shared", route: .replacement)))
        let replacementToken = try #require(store.immersiveSpaceLifecycleToken)
        let replacementTicket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: replacementToken))
        #expect(!admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: token, store: store, executionPrecondition: precondition))
        gate.release()
        #expect(await restoring.value == false)
        #expect(store.state.immersiveSpace?.route == .replacement)
        #expect(store.revision == 2)
        #expect(dismissals == (result == .opened ? 1 : 0))
        #expect(store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(id: "shared", lifecycleToken: replacementToken, ticket: replacementTicket))
    }

    @Test("A cancelled effect queue waiter never invokes native open")
    func cancelledWaiter() async throws {
        let gate = LateAppearanceGate()
        let blocker = Task { @MainActor in await RouterSceneRestorationRegistry.immersiveEffectQueue.enqueue { await gate.enter(); return true } }
        await gate.nextEntry()
        let store = try RouterStore(initialState: RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original)))
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        var opens = 0
        let waiter = Task { @MainActor in
            await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { opens += 1; return .error }, dismiss: {})
        }
        waiter.cancel()
        gate.release()
        _ = await blocker.value
        #expect(await waiter.value == false)
        #expect(opens == 0)
        #expect(store.state.immersiveSpace != nil)
        #expect(store.revision == 0)
    }

    @Test("Driver replacement during open retains the opening driver's compensation")
    func driverReplacement() async throws {
        let store = try RouterStore(initialState: RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original)))
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        let first = UUID(), second = UUID()
        let gate = LateAppearanceGate()
        var calls: [String] = []
        store.sceneRestorationRegistry.installImmersiveActions(.init(open: { _ in calls.append("first.open"); await gate.enter(); return .opened }, dismiss: { calls.append("first.dismiss") }), owner: first)
        let restoring = Task { @MainActor in await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { calls.append("fallback"); return .error }, dismiss: {}) }
        await gate.nextEntry()
        store.sceneRestorationRegistry.installImmersiveActions(.init(open: { _ in calls.append("second.open"); return .opened }, dismiss: { calls.append("second.dismiss") }), owner: second)
        store.sceneRestorationRegistry.removeImmersiveActions(owner: first)
        _ = await store.perform(.dismissImmersiveSpace)
        _ = await store.perform(.enterImmersiveSpace(.init(id: "shared", route: .replacement)))
        gate.release()
        #expect(await restoring.value == false)
        #expect(calls == ["first.open", "first.dismiss"])
        #expect(store.sceneRestorationRegistry.immersiveActions != nil)
        #expect(store.state.immersiveSpace?.route == .replacement)
    }

    @Test("Caller cancellation cannot abandon a returned native failure repair", arguments: [RouterImmersiveSpaceOpenResult.error, .userCancelled])
    func cancelledNativeOpen(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let initial = try RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original))
        let store = try RouterStore(initialState: initial)
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        let gate = LateAppearanceGate()
        let restoring = Task { @MainActor in
            await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { await gate.enter(); return result }, dismiss: {})
        }
        await gate.nextEntry()
        restoring.cancel()
        gate.release()
        #expect(await restoring.value == false)
        // reconcileSceneSystemFailure owns an uncancelled Task so a returned
        // native failure cannot strand canonical state merely because its
        // caller was cancelled (existing system-repair contract).
        #expect(store.state.immersiveSpace == nil)
        #expect(store.revision == 1)
        #expect(!store.sceneRestorationRegistry.isCurrentImmersiveSpaceRestoration(id: "shared", lifecycleToken: token, ticket: ticket))
    }

    @Test("Appearance before open returns invalidates error repair", arguments: [RouterImmersiveSpaceOpenResult.error, .userCancelled, .opened])
    func appearanceDuringOpen(_ result: RouterImmersiveSpaceOpenResult) async throws {
        let initial = try RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original))
        let store = try RouterStore(initialState: initial)
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let precondition = store.scope(at: .immersiveSpace("shared")).combinedExecutionPrecondition(nil)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        let gate = LateAppearanceGate()
        var dismissals = 0
        let restoring = Task { @MainActor in
            await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { await gate.enter(); return result }, dismiss: { dismissals += 1 })
        }
        await gate.nextEntry()
        #expect(admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: token, store: store, executionPrecondition: precondition))
        gate.release()
        #expect(await restoring.value == (result == .opened))
        #expect(store.state == initial)
        #expect(store.revision == 0)
        #expect(dismissals == 0)
    }

    @Test("Post-repair and explicit-close callbacks expose indistinguishable lifetime authority")
    func lateCallbackAuthorityGap() async throws {
        let initial = try RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original))
        let repaired = try RouterStore(initialState: initial)
        let explicit = try RouterStore(initialState: initial)
        let token = try #require(repaired.immersiveSpaceLifecycleToken)
        let ticket = try #require(repaired.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        _ = await repaired.perform(.push(.original))
        _ = await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: repaired, open: { .error }, dismiss: {})
        _ = await explicit.perform(.push(.original))
        _ = await explicit.perform(.dismissImmersiveSpace)
        #expect(repaired.state == explicit.state)
        #expect(repaired.revision == explicit.revision)
        #expect(repaired.immersiveSpaceLifecycleToken == nil)
        #expect(explicit.immersiveSpaceLifecycleToken == nil)
        #expect(repaired.sceneRequestLifetime(at: .immersiveSpace("shared")) == explicit.sceneRequestLifetime(at: .immersiveSpace("shared")))
        let repairedPrecondition = try #require(repaired.scope(at: .immersiveSpace("shared")).combinedExecutionPrecondition(nil))
        let explicitPrecondition = try #require(explicit.scope(at: .immersiveSpace("shared")).combinedExecutionPrecondition(nil))
        #expect(repairedPrecondition(repaired.state) == explicitPrecondition(explicit.state))
        // Neither helper call carries the opening request ID/native scene ID.
        #expect(!admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: nil, store: repaired, executionPrecondition: repairedPrecondition))
        #expect(!admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: nil, store: explicit, executionPrecondition: explicitPrecondition))
    }

    @Test("Policy deferral resolves after matching reappearance", arguments: ["allow", "reject", "cancel"])
    func deferredResolution(_ resolution: String) async throws {
        let deferral = RouterDeferralID()
        let store = try RouterStore(initialState: RouterState<LateAppearanceRoute>(immersiveSpace: .init(id: "shared", route: .original)), configuration: .init(policies: [RouterPolicy(name: "hold-close") { transition in
            if transition.action == .dismissImmersiveSpace { return .deferRequest(deferral) }
            return .allow
        }]))
        let token = try #require(store.immersiveSpaceLifecycleToken)
        let precondition = store.scope(at: .immersiveSpace("shared")).combinedExecutionPrecondition(nil)
        let ticket = try #require(store.sceneRestorationRegistry.beginImmersiveSpaceRestoration(id: "shared", lifecycleToken: token))
        let outcome = try #require(await synchronizeRouterImmersiveSpaceDisappearance(id: "shared", lifecycleToken: token, store: store))
        #expect(shouldRestoreRouterScene(after: outcome))
        #expect(store.revision == 0)
        #expect(await restoreRouterImmersiveSpaceAfterDeferredClosure(id: "shared", lifecycleToken: token, ticket: ticket, store: store, open: { .opened }, dismiss: {}))
        #expect(admitRouterImmersiveSpaceAppearance(id: "shared", lifecycleToken: token, store: store, executionPrecondition: precondition))
        if resolution == "allow" { _ = await store.resolveDeferred(deferral, with: .allow) }
        else if resolution == "reject" { _ = await store.resolveDeferred(deferral, with: .reject("keep")) }
        else { _ = await store.cancelDeferred(deferral) }
        #expect((store.state.immersiveSpace != nil) == (resolution != "allow"))
        #expect(store.revision == (resolution == "allow" ? 1 : 0))
    }
}
