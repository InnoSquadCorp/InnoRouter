import Foundation
import Observation
import Synchronization
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

@Suite("Scope lifetime contracts", .timeLimit(.minutes(1)))
@MainActor
struct RouterScopeLifetimeContractTests {
    private enum R: String, Route, Codable { case home, detail, replacement }

    private func state() throws -> RouterState<R> {
        try RouterState(root: .container(RouterContainerState(
            style: .tabs, selection: "left", branches: [
                .init(id: "left", node: .stack(path: [.home])),
                .init(id: "right", node: .stack(path: [.home])),
            ]
        )))
    }

    @Test("Same-shaped explicit replacement expires only its subtree and not sibling observations")
    func scopedReplacementAndObservation() async throws {
        let store = RouterStore(initialState: try state())
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"]), root = store.scope()
        let leftUpdates = Mutex(0), rightUpdates = Mutex(0), rootUpdates = Mutex(0), stateUpdates = Mutex(0)
        withObservationTracking { _ = store.scope(at: ["left"]) } onChange: { leftUpdates.withLock { $0 += 1 } }
        withObservationTracking { _ = store.scope(at: ["right"]) } onChange: { rightUpdates.withLock { $0 += 1 } }
        withObservationTracking { _ = store.scope() } onChange: { rootUpdates.withLock { $0 += 1 } }
        withObservationTracking { _ = store.state } onChange: { stateUpdates.withLock { $0 += 1 } }
        guard case .unchanged = await store.replaceSubtree(at: ["left"], with: .stack(path: [.home])) else {
            Issue.record("Equal replacement must not assign state"); return
        }
        #expect(store.revision == 0)
        #expect(leftUpdates.withLock { $0 } == 1)
        #expect(rightUpdates.withLock { $0 } == 0)
        #expect(rootUpdates.withLock { $0 } == 0)
        #expect(stateUpdates.withLock { $0 } == 0)
        #expect(left !== store.scope(at: ["left"]))
        #expect(right === store.scope(at: ["right"]))
        #expect(root === store.scope())
        #expect(left.node == nil)
        #expect(left.state == nil)
        guard case .rejected(_, _, _, .mutation(.expiredScope(["left"]))) = await left.performRoot(.select("right")) else {
            Issue.record("Replaced child must not use root authority"); return
        }
        guard case .applied = await right.perform(.push(.detail)) else { Issue.record("Live sibling rejected"); return }
    }

    @Test("Feature plans replace only the explicitly mapped owner lifetime")
    func featurePlanReplacement() async throws {
        let store = RouterStore(initialState: try state())
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        let mapping = RouterFeatureMapping<R, R>(id: "identity", namespace: "identity", route: .init(embed: { $0 }, extract: { $0 }))
        let feature = RouterFeatureScope(parent: left, mapping: mapping)
        guard case .unchanged = await feature.perform(.apply(.init(state: .rootStack(path: [.home])))) else {
            Issue.record("Feature equal plan must replace runtime owner only"); return
        }
        #expect(left.node == nil)
        #expect(left !== store.scope(at: ["left"]))
        #expect(right === store.scope(at: ["right"]))
        #expect(store.revision == 0)
    }

    @Test("Replacement intent remains deferred until policy allow and survives rebase")
    func deferredReplacement() async throws {
        let id = RouterDeferralID()
        let store = RouterStore(initialState: try state(), configuration: .init(policies: [
            .init(name: "hold-replacement") { transition in
                if case .apply = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(id) }
                return .allow
            },
        ]))
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"])
        guard case .deferred = await store.replaceSubtree(at: ["left"], with: .stack(path: [.home])) else {
            Issue.record("Expected equal replacement to require policy"); return
        }
        #expect(left === store.scope(at: ["left"]))
        _ = await right.perform(.push(.detail))
        guard case .unchanged = await store.resumeDeferred(id, strategy: .rebaseOnCurrentState) else {
            Issue.record("Rebase should preserve sibling and replace equal target ownership"); return
        }
        #expect(left !== store.scope(at: ["left"]))
        #expect(right === store.scope(at: ["right"]))
        #expect(store.revision == 1)
        #expect(store.state.node(at: ["right"]) == .stack(path: [.home, .detail]))
    }

    @Test("Expired queued feature ownership is checked before replacement preparation")
    func stalePreparation() async throws {
        let store = RouterStore(initialState: try state())
        let precondition = store.scopeLifetimePrecondition(at: ["left"])
        _ = await store.replaceSubtree(at: ["left"], with: .stack(path: [.home]))
        var preparations = 0
        let outcome = await store.perform(
            .push(.detail), context: .init(), expectedRevision: nil, bypassesPolicies: false,
            executionPrecondition: precondition,
            executionPreparation: { _ in preparations += 1; return .action(.push(.detail)) }
        )
        guard case .rejected = outcome else { Issue.record("Expected expired lifetime rejection"); return }
        #expect(preparations == 0)
        #expect(store.revision == 0)
    }

    @Test("Restore and explicit replacement preserve logical presentation ID conflict validation", arguments: [false, true])
    func identityConflictDoesNotRotate(useRestore: Bool) async throws {
        let id = UUID()
        let initial = try RouterState<R>(root: .stack(presentation: .init(id: id, route: .home, style: .sheet)))
        let store = RouterStore(initialState: initial)
        let scope = store.scope(), child = store.scope(at: .root.appendingPresentation(id))
        for replacement in [RouterPresentation<R>(id: id, route: .detail, style: .sheet), .init(id: id, route: .home, style: .popover)] {
            let outcome: RouterOutcome<R>
            if useRestore {
                let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
                outcome = try await store.restore(from: codec.encode(RouterState(root: .stack(presentation: replacement))), using: codec)
            } else {
                outcome = await store.replaceSubtree(with: .stack(presentation: replacement))
            }
            guard case .rejected(_, _, _, .mutation(.presentationIdentityConflict(id))) = outcome else {
                Issue.record("Same logical presentation ID must not change route/style"); return
            }
            #expect(store.state == initial)
            #expect(store.revision == 0)
            #expect(scope === store.scope())
            #expect(child === store.scope(at: .root.appendingPresentation(id)))
        }
    }

    @Test("Late cancelled presentation caller cannot dismiss a same-ID restored presentation")
    func oldCancellationOwnership() async throws {
        let store = RouterStore<R>()
        var events = store.events.makeAsyncIterator()
        let awaiter = Task { @MainActor in await store.present(.detail, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        let id = try #require(store.presentationWaiters.keys.first)
        let oldIdentity = try #require(store.presentationWaiters[id]?.identity)
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let target = store.state
        _ = try await store.restore(from: codec.encode(target), using: codec)
        #expect(await awaiter.value == .dismissed)
        await store.cancelPresentation(id: id, at: .root, waiterIdentity: oldIdentity)
        #expect(store.state == target)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Deferred old typed completion cannot return its value into a restored presentation")
    func deferredCompletionOwnership() async throws {
        let deferral = RouterDeferralID()
        let store = RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold-finish") { transition in
                if case .dismissPresentation = transition.action, transition.context.resumedDeferral == nil { return .deferRequest(deferral) }
                return .allow
            },
        ]))
        var events = store.events.makeAsyncIterator()
        let awaiter = Task { @MainActor in await store.present(.detail, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        do { try await store.finishPresentation(returning: "old-value"); Issue.record("Expected deferred finish") }
        catch { #expect(error as? RouterPresentationCompletionError == .dismissalDeferred(deferral)) }
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let target = store.state
        _ = try await store.restore(from: codec.encode(target), using: codec)
        #expect(await awaiter.value == .dismissed)
        guard case .rejected = await store.resumeDeferred(deferral, strategy: .rebaseOnCurrentState) else {
            Issue.record("Old completion must not dismiss replacement"); return
        }
        #expect(store.state == target)
        #expect(store.revision == 1)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Restore terminates a pending presentation whose owner disappeared before it committed")
    func pendingWaiterOwnership() async throws {
        let deferral = RouterDeferralID()
        let store = RouterStore<R>(configuration: .init(policies: [
            .init(name: "hold-present") { transition in
                if case .present = transition.action { return .deferRequest(deferral) }
                return .allow
            },
        ]))
        var events = store.events.makeAsyncIterator()
        let awaiter = Task { @MainActor in await store.present(.detail, expecting: String.self) }
        while let event = await events.next() { if case .deferred = event { break } }
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        _ = try await store.restore(from: codec.encode(store.state), using: codec)
        #expect(await awaiter.value == .dismissed)
        #expect(store.presentationWaiters.isEmpty)
        guard case .rejected = await store.resumeDeferred(deferral, strategy: .rebaseOnCurrentState) else {
            Issue.record("Pending presentation must not attach to new owner"); return
        }
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
    }

    @Test("Deferred owning-Store replacement does not retarget a replaced subtree")
    func owningReplacementRebaseOwnership() async throws {
        let deferral = RouterDeferralID()
        let store = RouterStore(initialState: try state(), configuration: .init(policies: [
            .init(name: "hold-replacement") { transition in
                if transition.context.source == .application, transition.context.resumedDeferral == nil {
                    return .deferRequest(deferral)
                }
                return .allow
            },
        ]))
        guard case .deferred = await store.replaceSubtree(at: ["left"], with: .stack(path: [.detail])) else {
            Issue.record("Expected replacement deferral"); return
        }
        _ = await store.replaceSubtree(at: ["left"], with: .stack(path: [.replacement]), context: .init(source: .system))
        guard case .rejected(_, _, _, .mutation(.expiredScope(["left"]))) = await store.resumeDeferred(deferral, strategy: .rebaseOnCurrentState) else {
            Issue.record("Rebase must retain initial target lifetime"); return
        }
        #expect(store.state.node(at: ["left"]) == .stack(path: [.replacement]))
        #expect(store.revision == 1)
    }

    @Test("Real request observations flag nonportable ownership without persisting runtime tokens")
    func replayLimitations() async {
        let store = RouterStore<R>()
        var observations: [RouterRequestObservation<R>] = []
        let observer = store.addSynchronousRequestObserver { observations.append($0) }
        defer { store.removeSynchronousRequestObserver(observer) }
        _ = await store.perform(.push(.home))
        _ = await store.scope().perform(.push(.detail))
        _ = await store.replaceSubtree(with: .stack(path: [.home, .detail]))
        #expect(observations.map(\.replayLimitationCode) == [
            nil, "runtime.executionPrecondition", "runtime.ownershipReplacement",
        ])
    }

    @Test("Missing cache identity stays stable but never revives across creation and removal")
    func missingCacheIdentity() async throws {
        let store = RouterStore<R>()
        let missing = store.scope(at: ["left"])
        #expect(missing === store.scope(at: ["left"]))
        #expect(missing.node == nil)
        _ = await store.perform(.apply(.init(state: try state())))
        let live = store.scope(at: ["left"])
        #expect(missing !== live)
        guard case .rejected(_, _, _, .mutation(.expiredScope(["left"]))) = await missing.perform(.push(.detail)) else {
            Issue.record("Missing capture acquired created scope"); return
        }
        _ = await store.perform(.apply(.init(state: .rootStack)))
        let nextMissing = store.scope(at: ["left"])
        #expect(nextMissing !== live)
        #expect(nextMissing === store.scope(at: ["left"]))
        #expect(missing.node == nil)
        #expect(live.node == nil)
        #expect(store.revision == 2)
    }

    @Test("Transient scopes do not accumulate runtime tokens or observation slots")
    func registryCleanup() async throws {
        let store = RouterStore<R>()
        for _ in 0..<100 {
            let id = UUID()
            _ = await store.perform(.openWindow(.init(id: id, route: .home)))
            do { let scope = store.scope(at: .window(id)); #expect(scope.node != nil) }
            _ = await store.perform(.dismissWindow(id))
            store.compactDeadScopes()
        }
        #expect(store.scopeLifetimes.count == 1)
        #expect(store.cachedScopeCount == 0)
        #expect(store.scopeLifetimeObservations.isEmpty)
    }

    @Test("Late scene callbacks reject captured runtime rights while fresh callbacks retain native identity")
    func sceneCallbackOwnership() async throws {
        let id = UUID()
        let initial = try RouterState<R>(windows: [.init(id: id, route: .home)], immersiveSpace: .init(id: "space", route: .home))
        let store = RouterStore(initialState: initial)
        let windowNative = try #require(store.windowLifecycleTokens[id])
        let immersiveNative = try #require(store.immersiveSpaceLifecycleToken)
        let oldWindow = store.scopeLifetimePrecondition(at: .window(id))
        let oldImmersive = store.scopeLifetimePrecondition(at: .immersiveSpace("space"))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        _ = try await store.restore(from: codec.encode(initial), using: codec)
        #expect(await synchronizeRouterWindowDisappearance(id: id, lifecycleToken: windowNative, store: store, executionPrecondition: oldWindow) == nil)
        #expect(await synchronizeRouterImmersiveSpaceDisappearance(id: "space", lifecycleToken: immersiveNative, store: store, executionPrecondition: oldImmersive) == nil)
        #expect(store.state == initial)
        #expect(store.windowLifecycleTokens[id] == windowNative)
        #expect(store.immersiveSpaceLifecycleToken == immersiveNative)
        guard case .applied = await synchronizeRouterWindowDisappearance(id: id, lifecycleToken: windowNative, store: store) else { Issue.record("Fresh window callback must apply"); return }
        guard case .applied = await synchronizeRouterImmersiveSpaceDisappearance(id: "space", lifecycleToken: immersiveNative, store: store) else { Issue.record("Fresh space callback must apply"); return }
        #expect(store.state.windows.isEmpty)
        #expect(store.state.immersiveSpace == nil)
    }
}
