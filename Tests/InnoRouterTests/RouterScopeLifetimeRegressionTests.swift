import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

/// Existing APIs only: these tests also compile against the pre-fix engine.
@Suite("Scope lifetime regressions", .timeLimit(.minutes(1)))
@MainActor
struct RouterScopeLifetimeRegressionTests {
    private enum R: String, Route, Codable { case home, detail, replacement }

    private func tabs() throws -> RouterState<R> {
        try RouterState(root: .container(RouterContainerState(
            style: .tabs, selection: "left", branches: [
                .init(id: "left", node: .stack(path: [.home])),
                .init(id: "right", node: .stack(path: [.home])),
            ]
        )))
    }

    private func expectRejected(_ outcome: RouterOutcome<R>) {
        guard case .rejected = outcome else {
            Issue.record("Expired authority must reject without a mutation")
            return
        }
    }

    @Test("Removed presentation child cannot escape to owning root")
    func removedPresentationChildRootEscape() async {
        let id = UUID()
        let store = RouterStore<R>()
        _ = await store.perform(.present(.init(id: id, route: .detail, style: .sheet)))
        let child = store.scope(at: .root.appendingPresentation(id))
        _ = await store.perform(.dismissPresentation)
        let revision = store.revision
        expectRejected(await child.perform(.push(.detail)))
        expectRejected(await child.performRoot(.push(.replacement)))
        #expect(store.state == .rootStack)
        #expect(store.revision == revision)
        guard case .applied = await store.perform(.push(.home)) else {
            Issue.record("Owning Store must retain explicit root authority")
            return
        }
    }

    @Test("Closed and recreated scene cannot revive root forwarding")
    func closedSceneRootEscape() async throws {
        let id = UUID()
        let store = RouterStore<R>(initialState: try RouterState(windows: [.init(id: id, route: .home)]))
        let old = store.scope(at: .window(id))
        _ = await store.perform(.dismissWindow(id))
        _ = await store.perform(.openWindow(.init(id: id, route: .home)))
        let revision = store.revision
        #expect(old !== store.scope(at: .window(id)))
        expectRejected(await old.perform(.push(.detail)))
        expectRejected(await old.performRoot(.push(.replacement)))
        #expect(store.state.root == .stack())
        #expect(store.revision == revision)
    }

    @Test("Same persisted scene UUID after restore gets new runtime authority without native reopening")
    func restoredSameSceneIdentity() async throws {
        let id = UUID()
        let store = RouterStore<R>(initialState: try RouterState(windows: [.init(id: id, route: .home)]))
        let old = store.scope(at: .window(id))
        let nativeToken = store.windowLifecycleTokens[id]
        let replacement = try RouterState<R>(windows: [.init(id: id, route: .home, node: .stack(path: [.replacement]))])
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        _ = try await store.restore(from: codec.encode(replacement), using: codec)
        #expect(store.windowLifecycleTokens[id] == nativeToken)
        #expect(old !== store.scope(at: .window(id)))
        expectRejected(await old.perform(.push(.detail)))
        #expect(store.state == replacement)
        #expect(store.revision == 1)
    }

    @Test("An absent scope never gains authority when its path is later created")
    func missingThenCreated() async throws {
        let store = RouterStore<R>()
        let absent = store.scope(at: ["left"])
        let target = try tabs()
        _ = await store.perform(.apply(.init(state: target)))
        expectRejected(await absent.perform(.push(.detail)))
        expectRejected(await absent.performRoot(.select("right")))
        #expect(store.state == target)
        #expect(absent !== store.scope(at: ["left"]))
    }

    @Test("Removed and recreated branch rejects old callbacks with its reused declaration ID")
    func branchRemoveRecreate() async throws {
        let state = try tabs()
        let store = RouterStore(initialState: state)
        let old = store.scope(at: ["left"])
        let reduced = try RouterState<R>(root: .container(RouterContainerState(
            style: .tabs, selection: "right", branches: [.init(id: "right", node: .stack(path: [.home]))]
        )))
        _ = await store.perform(.apply(.init(state: reduced)))
        _ = await store.perform(.apply(.init(state: state)))
        expectRejected(await old.perform(.push(.detail)))
        #expect(store.state == state)
        #expect(store.revision == 2)
    }

    @Test("Equal exact restore checks policies and rotates ownership without state revision")
    func equalRestore() async throws {
        var policyCalls = 0
        let store = RouterStore<R>(configuration: .init(policies: [
            .init(name: "restore-authorization") { _ in policyCalls += 1; return .allow },
        ]))
        let old = store.scope()
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        guard case .unchanged = try await store.restore(from: codec.encode(store.state), using: codec) else {
            Issue.record("Equal restore must not assign state or increment revision")
            return
        }
        #expect(policyCalls == 1)
        #expect(store.revision == 0)
        #expect(old !== store.scope())
        expectRejected(await old.performRoot(.push(.detail)))
        #expect(store.state == .rootStack)
    }

    @Test("Rejected equal restore preserves all previous ownership")
    func rejectedEqualRestore() async throws {
        let store = RouterStore<R>(configuration: .init(policies: [
            .init(name: "deny-restore") { _ in .reject("denied") },
        ]))
        let scope = store.scope()
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        expectRejected(try await store.restore(from: codec.encode(store.state), using: codec))
        #expect(scope === store.scope())
        #expect(scope.node == .stack())
        #expect(store.revision == 0)
    }

    @Test("Queued tab callback is rejected after same-ID restore, without rejecting normal current callback")
    func queuedCallbackAfterRestore() async throws {
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let (queued, queuedContinuation) = AsyncStream<Void>.makeStream()
        var configuration = RouterStoreConfiguration<R>(policies: [
            .init(name: "hold-restore") { transition in
                if transition.context.source == .restoration {
                    enteredContinuation.yield(())
                    for await _ in release { break }
                }
                return .allow
            },
        ])
        configuration.runtimeDependencies.didQueueRequest = { _ in queuedContinuation.yield(()) }
        let store = RouterStore(initialState: try tabs(), configuration: configuration)
        let oldRoot = store.scope()
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        let data = try codec.encode(store.state)
        let restore = Task { @MainActor in try await store.restore(from: data, using: codec) }
        var entry = entered.makeAsyncIterator()
        // Baseline skips policy on equal state; use request completion to avoid
        // a hanging witness while still fail-closing the assertion.
        let completion = Task { @MainActor in
            _ = try? await restore.value
            enteredContinuation.yield(())
        }
        _ = await entry.next()
        let callback = Task { @MainActor in await oldRoot.performRoot(.select("right")) }
        if store.activeTransitionID != nil {
            var queue = queued.makeAsyncIterator()
            _ = await queue.next()
        }
        releaseContinuation.yield(())
        releaseContinuation.finish()
        _ = try await restore.value
        _ = await completion.value
        expectRejected(await callback.value)
        #expect(store.state == (try tabs()))
        #expect(store.revision == 0)
        guard case .applied = await store.scope().performRoot(.select("right")) else {
            Issue.record("A newly acquired tab callback should apply")
            return
        }
    }

    @Test("Rebased deferral retains original runtime authority after same-ID restore")
    func deferredRebaseAfterRestore() async throws {
        let id = RouterDeferralID()
        let store = RouterStore<R>(configuration: .init(policies: [
            .init(name: "approval") { transition in
                if case .push = transition.action, transition.context.resumedDeferral == nil {
                    return .deferRequest(id)
                }
                return .allow
            },
        ]))
        let old = store.scope()
        guard case .deferred = await old.perform(.push(.detail)) else {
            Issue.record("Expected original request to defer")
            return
        }
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        _ = try await store.restore(from: codec.encode(store.state), using: codec)
        expectRejected(await store.resumeDeferred(id, strategy: .rebaseOnCurrentState))
        #expect(store.state == .rootStack)
        #expect(store.revision == 0)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("Same presentation UUID restore retires the old waiter instead of returning the new result")
    func restoredPresentationWaiter() async throws {
        let store = RouterStore<R>()
        var events = store.events.makeAsyncIterator()
        let awaiter = Task { @MainActor in await store.present(.detail, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        guard case .stack(let stack) = store.state.root, var presentation = stack.presentation else {
            Issue.record("Expected awaited presentation"); awaiter.cancel(); return
        }
        let conflicting = try RouterState<R>(root: .stack(presentation: .init(
            id: presentation.id, route: .replacement, style: .sheet
        )))
        #expect(await store.perform(.apply(.init(state: conflicting))).rejectionReason == .mutation(.presentationIdentityConflict(presentation.id)))
        presentation.node = .stack(path: [.replacement])
        let target = try RouterState(root: .stack(presentation: presentation))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1)
        _ = try await store.restore(from: codec.encode(target), using: codec)
        #expect(store.presentationWaiters[presentation.id] == nil)
        // Complete the baseline waiter too, so the pre-fix result is a prompt
        // assertion failure rather than a timeout or leaked task.
        if store.presentationWaiters[presentation.id] != nil {
            try await store.finishPresentation(returning: "replacement-result")
        }
        #expect(await awaiter.value == .dismissed)
    }

    @Test("Removing an outer presentation terminates its nested awaited result exactly once")
    func nestedWaiterRemoval() async {
        let store = RouterStore<R>()
        let id = UUID()
        _ = await store.perform(.present(.init(id: id, route: .home, style: .sheet)))
        let child = store.scope(at: .root.appendingPresentation(id))
        var events = store.events.makeAsyncIterator()
        let awaiter = Task { @MainActor in await child.present(.detail, expecting: String.self) }
        while let event = await events.next() { if case .committed = event { break } }
        _ = await store.perform(.dismissPresentation)
        #expect(store.presentationWaiters.isEmpty)
        if !store.presentationWaiters.isEmpty { awaiter.cancel() }
        #expect(await awaiter.value == .dismissed)
        #expect(store.state == .rootStack)
        #expect(store.presentationWaiters.isEmpty)
    }

    @Test("Ordinary push pop selection badge and apply preserve retained sibling and root identities")
    func ordinaryReconciliationControl() async throws {
        let store = RouterStore(initialState: try tabs())
        let left = store.scope(at: ["left"]), right = store.scope(at: ["right"]), root = store.scope()
        _ = await right.perform(.push(.detail))
        _ = await right.perform(.pop(count: 1))
        _ = await root.perform(.select("right"))
        _ = await root.perform(.setBadge(2, for: "left"))
        let plan = try store.state.replacingNode(.stack(path: [.replacement]), at: ["right"])
        _ = await store.perform(.apply(.init(state: plan)))
        #expect(left === store.scope(at: ["left"]))
        #expect(right === store.scope(at: ["right"]))
        #expect(root === store.scope())
        guard case .applied = await left.perform(.push(.detail)) else {
            Issue.record("Unrelated branch edits must preserve the live scope")
            return
        }
        #expect(store.state.node(at: ["left"]) == .stack(path: [.home, .detail]))
        #expect(store.state.node(at: ["right"]) == .stack(path: [.replacement]))
    }
}

private extension RouterOutcome {
    var rejectionReason: RouterRejectionReason? {
        if case .rejected(_, _, _, let reason) = self { return reason }
        return nil
    }
}
