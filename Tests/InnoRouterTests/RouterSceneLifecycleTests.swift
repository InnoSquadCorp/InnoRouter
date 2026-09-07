import Foundation
import SwiftUI
import Testing

import InnoRouter
@testable import InnoRouterSwiftUI

private enum SceneLifecycleRoute: Route, RouterSceneRoute, DestinationRoute {
    case editor
    case theater

    static let routerScenes: [RouterSceneDescriptor<Self>] = [
        .init(route: .editor, id: "editor", style: .window),
        .init(route: .theater, id: "theater", style: .immersiveSpace),
    ]

    @MainActor
    static func destination(for route: Self) -> some View {
        _ = route
        return EmptyView()
    }
}

private enum PlainSceneLifecycleRoute: Route {
    case old
    case replacement
}

@MainActor
private final class SceneLifecyclePolicyGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@Suite("Router scene lifecycle")
@MainActor
struct RouterSceneLifecycleTests {
    @Test("Manual scene catalogs fail with typed validation errors")
    func manualSceneCatalogValidation() throws {
        #expect(throws: RouterSceneCatalogError.empty) {
            try RouterSceneCatalog<SceneLifecycleRoute>([])
        }
        #expect(throws: RouterSceneCatalogError.emptyIdentifier) {
            try RouterSceneCatalog<SceneLifecycleRoute>([
                .init(route: .editor, id: " ", style: .window)
            ])
        }
        #expect(throws: RouterSceneCatalogError.duplicateIdentifier("shared")) {
            try RouterSceneCatalog<SceneLifecycleRoute>([
                .init(route: .editor, id: "shared", style: .window),
                .init(route: .theater, id: "shared", style: .immersiveSpace),
            ])
        }

        _ = try RouterSceneCatalog(SceneLifecycleRoute.routerScenes)
    }

    @Test("Macro-first scene actions validate catalog style and identity before commit")
    func sceneActionAdmission() async throws {
        let store = RouterStore<SceneLifecycleRoute>()
        let actions = RouterActions(
            authority: RouterAuthority(scope: store.scope())
        )

        let wrongStyle = await actions.openWindow(.theater).value
        guard case .rejected(_, _, _, let wrongStyleReason) = wrongStyle else {
            Issue.record("Expected a catalog style rejection")
            return
        }
        #expect(
            wrongStyleReason == .mutation(
                .unsupportedScene(
                    routeType: String(describing: SceneLifecycleRoute.self),
                    style: RouterSceneStyle.window.rawValue
                )
            )
        )

        let wrongID = await actions.enterImmersiveSpace(
            id: "other",
            route: .theater
        ).value
        #expect(
            wrongID.rejectionReason == .mutation(
                .sceneIdentifierMismatch(expected: "theater", actual: "other")
            )
        )
        #expect(store.revision == 0)
        #expect(store.state.windows.isEmpty)
        #expect(store.state.immersiveSpace == nil)

        let directWrongStyle = await store.perform(
            .openWindow(.init(route: .theater))
        )
        #expect(
            directWrongStyle.rejectionReason == .mutation(
                .unsupportedScene(
                    routeType: String(describing: SceneLifecycleRoute.self),
                    style: RouterSceneStyle.window.rawValue
                )
            )
        )

        let invalidImmersiveState = try RouterState<SceneLifecycleRoute>(
            immersiveSpace: .init(id: "other", route: .theater)
        )
        let directWrongID = await store.perform(
            .apply(RouterPlan(state: invalidImmersiveState))
        )
        #expect(
            directWrongID.rejectionReason == .mutation(
                .sceneIdentifierMismatch(expected: "theater", actual: "other")
            )
        )

#if !os(visionOS)
        let unavailableImmersive = await actions.enterImmersiveSpace(
            id: "theater",
            route: .theater
        ).value
        #expect(
            unavailableImmersive.rejectionReason == .mutation(
                .unsupportedScene(
                    routeType: String(describing: SceneLifecycleRoute.self),
                    style: RouterSceneStyle.immersiveSpace.rawValue
                )
            )
        )
#endif

#if os(tvOS) || os(watchOS)
        let unavailableWindow = await actions.openWindow(.editor).value
        #expect(
            unavailableWindow.rejectionReason == .mutation(
                .unsupportedScene(
                    routeType: String(describing: SceneLifecycleRoute.self),
                    style: RouterSceneStyle.window.rawValue
                )
            )
        )
#else
        guard case .applied = await actions.openWindow(
            RouterWindowRequest(route: .editor, sceneID: "editor")
        ).value else {
            Issue.record("Expected a valid catalog window to commit")
            return
        }
        #expect(store.state.windows.count == 1)
#endif
    }

    @Test("Scene hosts project independent scene-local scopes")
    func sceneHostScopes() async throws {
        let windowID = UUID()
        let state = try RouterState<SceneLifecycleRoute>(
            windows: [.init(id: windowID, route: .editor)]
        )
        let store = RouterStore(initialState: state)

        _ = RouterWindowHost(id: windowID, store: store).body
        let outcome = await store.perform(
            RouterAction.push(.theater).inScope(.window(windowID))
        )

        guard case .applied = outcome else {
            Issue.record("Expected window-local navigation to commit")
            return
        }
        #expect(store.state.root == .stack())
        #expect(store.state.node(at: .window(windowID)) == .stack(path: [.theater]))
    }

    @Test("Interactive window closure removes the exact ID with system provenance")
    func windowClosure() async throws {
        let windowID = UUID()
        let state = try RouterState(
            windows: [RouterWindow(id: windowID, route: SceneLifecycleRoute.editor)]
        )
        let store = RouterStore(initialState: state)
        var events = store.events.makeAsyncIterator()

        let outcome = await synchronizeRouterWindowDisappearance(
            id: windowID,
            store: store
        )

        guard case .applied = outcome else {
            Issue.record("Expected the native window close to update router state")
            return
        }
        guard case .started(let transition) = await events.next() else {
            Issue.record("Expected a correlated system transition")
            return
        }
        #expect(transition.context.source == .system)
        #expect(store.state.windows.isEmpty)
        #expect(
            await synchronizeRouterWindowDisappearance(id: windowID, store: store) == nil
        )
    }

    @Test("Interactive immersive dismissal removes only the matching space")
    func immersiveDismissal() async throws {
        let state = try RouterState(
            immersiveSpace: RouterImmersiveSpace(
                id: "theater",
                route: SceneLifecycleRoute.theater
            )
        )
        let store = RouterStore(initialState: state)
        var events = store.events.makeAsyncIterator()

        let unrelated = await synchronizeRouterImmersiveSpaceDisappearance(
            id: "other",
            store: store
        )
        let matching = await synchronizeRouterImmersiveSpaceDisappearance(
            id: "theater",
            store: store
        )

        #expect(unrelated == nil)
        guard case .applied = matching else {
            Issue.record("Expected the matching immersive space to be dismissed")
            return
        }
        guard case .started(let transition) = await events.next() else {
            Issue.record("Expected a correlated system transition")
            return
        }
        #expect(transition.context.source == .system)
        #expect(store.state.immersiveSpace == nil)
        #expect(
            await synchronizeRouterImmersiveSpaceDisappearance(
                id: "theater",
                store: store
            ) == nil
        )
    }

    @Test("A stale immersive dismissal cannot remove a replacement space")
    func staleImmersiveDismissalCannotRemoveReplacement() async throws {
        let gate = SceneLifecyclePolicyGate()
        let initialState = try RouterState<PlainSceneLifecycleRoute>(
            immersiveSpace: .init(id: "old", route: .old)
        )
        let replacementState = try RouterState<PlainSceneLifecycleRoute>(
            immersiveSpace: .init(id: "replacement", route: .replacement)
        )
        let store = RouterStore(
            initialState: initialState,
            configuration: .init(
                policies: [
                    RouterPolicy(name: "replacement-gate") { transition in
                        guard case .apply = transition.action else { return .allow }
                        await gate.wait()
                        return .allow
                    }
                ]
            )
        )
        let replacement = Task { @MainActor in
            await store.perform(.apply(.init(state: replacementState)))
        }
        await gate.waitUntilEntered()
        var observations = store.requestObservations.makeAsyncIterator()
        let disappearance = Task { @MainActor in
            await synchronizeRouterImmersiveSpaceDisappearance(id: "old", store: store)
        }
        while let observation = await observations.next() {
            if observation.action == .dismissImmersiveSpace { break }
        }

        gate.release()
        guard case .applied = await replacement.value else {
            Issue.record("Expected the replacement space to commit")
            return
        }
        guard case .rejected(_, _, _, .mutation(.immersiveSpaceNotFound("old"))) =
                await disappearance.value else {
            Issue.record("Expected the stale disappearance to be rejected")
            return
        }
        #expect(store.state == replacementState)
        #expect(store.revision == 1)
    }

    @Test("A deferred immersive disappearance rechecks the original lifetime")
    func deferredImmersiveDisappearanceCannotRemoveReplacement() async throws {
        let deferralID = RouterDeferralID()
        let initialState = try RouterState<PlainSceneLifecycleRoute>(
            immersiveSpace: .init(id: "old", route: .old)
        )
        let replacementState = try RouterState<PlainSceneLifecycleRoute>(
            immersiveSpace: .init(id: "replacement", route: .replacement)
        )
        let store = RouterStore(
            initialState: initialState,
            configuration: .init(
                policies: [
                    RouterPolicy(name: "approval") { transition in
                        guard transition.action == .dismissImmersiveSpace,
                              transition.context.resumedDeferral == nil else {
                            return .allow
                        }
                        return .deferRequest(deferralID)
                    }
                ]
            )
        )

        guard case .deferred = await synchronizeRouterImmersiveSpaceDisappearance(
            id: "old",
            store: store
        ) else {
            Issue.record("Expected the native disappearance to defer")
            return
        }
        guard case .applied = await store.perform(.apply(.init(state: replacementState))) else {
            Issue.record("Expected the replacement space to commit")
            return
        }
        guard case .rejected(_, _, _, .mutation(.immersiveSpaceNotFound("old"))) =
                await store.resumeDeferred(deferralID, strategy: .rebaseOnCurrentState) else {
            Issue.record("Expected resumed stale disappearance to reject")
            return
        }

        #expect(store.state == replacementState)
        #expect(store.revision == 1)
        #expect(store.deferredTransitions.isEmpty)
    }

    @Test("A late disappearance cannot close a new generation with the same scene ID")
    func immersiveLifecycleTokenDistinguishesReentry() async throws {
        let initialState = try RouterState<PlainSceneLifecycleRoute>(
            immersiveSpace: .init(id: "shared", route: .old)
        )
        let store = RouterStore(initialState: initialState)
        let previousToken = try #require(store.immersiveSpaceLifecycleToken)

        guard case .applied = await store.perform(
            .push(.replacement).inScope(.immersiveSpace("shared"))
        ) else {
            Issue.record("Expected an in-space navigation update to commit")
            return
        }
        #expect(store.immersiveSpaceLifecycleToken == previousToken)

        _ = await store.perform(.dismissImmersiveSpace)
        _ = await store.perform(
            .enterImmersiveSpace(.init(id: "shared", route: .old))
        )
        let outcome = await synchronizeRouterImmersiveSpaceDisappearance(
            id: "shared",
            lifecycleToken: previousToken,
            store: store
        )

        #expect(outcome == nil)
        #expect(store.state.immersiveSpace?.id == "shared")
        #expect(store.revision == 3)
        #expect(store.immersiveSpaceLifecycleToken != previousToken)
    }

    @Test("Rejected immersive closure preserves canonical state")
    func rejectedImmersiveClosure() async throws {
        let state = try RouterState<PlainSceneLifecycleRoute>(
            immersiveSpace: .init(id: "protected", route: .old)
        )
        let store = RouterStore(
            initialState: state,
            configuration: .init(
                policies: [
                    RouterPolicy(name: "protected-space") { transition in
                        transition.action == .dismissImmersiveSpace
                            ? .reject("keep open")
                            : .allow
                    }
                ]
            )
        )

        guard case .rejected(_, _, _, .policy(name: "protected-space", message: "keep open")) =
                await synchronizeRouterImmersiveSpaceDisappearance(
                    id: "protected",
                    store: store
                ) else {
            Issue.record("Expected application policy to reject native closure")
            return
        }
        #expect(store.state == state)
        #expect(store.revision == 0)
    }

    @Test("Rejected native closure leaves canonical scene state intact")
    func rejectedClosure() async throws {
        let windowID = UUID()
        let state = try RouterState(
            windows: [RouterWindow(id: windowID, route: SceneLifecycleRoute.editor)]
        )
        let store = RouterStore(
            initialState: state,
            configuration: .init(
                policies: [
                    RouterPolicy(name: "protected-window") { transition in
                        if case .dismissWindow = transition.action {
                            return .reject("Save before closing")
                        }
                        return .allow
                    },
                ]
            )
        )

        let outcome = await synchronizeRouterWindowDisappearance(
            id: windowID,
            store: store
        )

        guard case .rejected = outcome else {
            Issue.record("Expected the policy to reject native closure")
            return
        }
        #expect(store.state.windows.map(\.id) == [windowID])
    }

    @Test("A failed native open repair cannot be rejected by application policy")
    func nativeOpenFailureRepair() async throws {
        let windowID = UUID()
        let state = try RouterState(
            windows: [RouterWindow(id: windowID, route: SceneLifecycleRoute.editor)]
        )
        let store = RouterStore(
            initialState: state,
            configuration: .init(
                policies: [
                    RouterPolicy(name: "preserve-window") { _ in .reject("keep") },
                ]
            )
        )

        let outcome = await store.reconcileSceneSystemFailure(
            .dismissWindow(windowID),
            expectedRevision: 0
        )

        guard case .applied = outcome else {
            Issue.record("Expected native failure repair to commit")
            return
        }
        #expect(store.state.windows.isEmpty)
    }
}

private extension RouterOutcome {
    var rejectionReason: RouterRejectionReason? {
        guard case .rejected(_, _, _, let reason) = self else { return nil }
        return reason
    }
}
