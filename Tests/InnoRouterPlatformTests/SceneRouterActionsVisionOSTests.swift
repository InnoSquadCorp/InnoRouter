#if os(visionOS)

import Foundation
import SwiftUI
import Testing
import UIKit

import InnoRouterCore
import InnoRouterSwiftUI
@testable import InnoRouterSpatial

private enum SceneActionsSpatialRoute: Route {
    case main
    case model
    case theatre
    case undeclared
}

@MainActor
private final class SceneEnvironmentProbeRecorder {
    var openedPresentation: ScenePresentation<SceneActionsSpatialRoute>?
}

private struct SceneEnvironmentProbe: View {
    @EnvironmentSceneRouter(SceneActionsSpatialRoute.self)
    private var scenes

    let route: SceneActionsSpatialRoute
    let recorder: SceneEnvironmentProbeRecorder

    var body: some View {
        Color.clear.onAppear {
            recorder.openedPresentation = scenes.open(route)
        }
    }
}

@Suite("visionOS route-aware scene actions", .tags(.unit))
@MainActor
struct SceneRouterActionsVisionOSTests {
    private let size = VolumetricSize(x: 0.6, y: 0.4, z: 0.4)

    @Test("open maps declarations to window, volumetric, and immersive handles")
    func openUsesDeclaredKindAndMetadata() throws {
        let (store, scenes, actions) = makeSystem()
        let dispatcherToken = UUID()
        #expect(store.registerDispatcherHost(dispatcherToken))

        let window = try #require(actions.open(.main))
        #expect(try claimOpen(store, dispatcherToken: dispatcherToken) == window)
        guard case .window(.main, _) = window else {
            Issue.record("Expected a window handle, got \(window)")
            return
        }

        let volume = try #require(actions.open(.model))
        #expect(try claimOpen(store, dispatcherToken: dispatcherToken) == volume)
        guard case .volumetric(.model, let openedSize, _) = volume else {
            Issue.record("Expected a volumetric handle, got \(volume)")
            return
        }
        #expect(openedSize == size)

        let immersive = try #require(actions.open(.theatre))
        #expect(try claimOpen(store, dispatcherToken: dispatcherToken) == immersive)
        guard case .immersive(.theatre, let style, _) = immersive else {
            Issue.record("Expected an immersive handle, got \(immersive)")
            return
        }
        #expect(style == .mixed)

        _ = scenes
    }

    @Test("An undeclared route returns nil without queueing a request")
    func undeclaredRouteReturnsNil() {
        let (store, _, actions) = makeSystem(policy: .logAndDegrade)

        #expect(actions.open(.undeclared) == nil)
        #expect(store.currentPendingRequestID == nil)
    }

    @Test("dismiss actions preserve window identity and immersive semantics")
    func dismissActionsMapToStoreIntents() throws {
        let (store, scenes, actions) = makeSystem()
        let dispatcherToken = UUID()
        #expect(store.registerDispatcherHost(dispatcherToken))

        let windowID = UUID()
        let windowLifecycleToken = UUID()
        let window = store.registerSceneLifecycle(
            route: .main,
            scenes: scenes,
            instanceID: windowID,
            token: windowLifecycleToken
        )
        actions.dismissWindow(window)
        #expect(
            try claimIntent(store, dispatcherToken: dispatcherToken) == .dismissWindow(window)
        )
        let windowDismissRequestID = try #require(store.currentClaimedRequestID)
        _ = try #require(
            store.completeClaimedDismissal(
                of: window,
                requestID: windowDismissRequestID
            )
        )
        store.unregisterSceneLifecycle(windowLifecycleToken)

        let immersiveLifecycleToken = UUID()
        _ = store.registerSceneLifecycle(
            route: .theatre,
            scenes: scenes,
            instanceID: nil,
            token: immersiveLifecycleToken
        )
        actions.dismissImmersive()
        #expect(
            try claimIntent(store, dispatcherToken: dispatcherToken) == .dismissImmersive
        )
    }

    @Test("SceneHost publishes its route-aware authority to descendants")
    func sceneHostPublishesEnvironmentAuthority() {
        let (store, scenes, _) = makeSystem()
        let recorder = SceneEnvironmentProbeRecorder()
        let controller = render(
            SceneEnvironmentProbe(route: .theatre, recorder: recorder)
                .innoRouterSceneHost(
                    store,
                    scenes: scenes,
                    attachedTo: .main,
                    instanceID: UUID()
                )
                .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
        )

        #expect(recorder.openedPresentation != nil)
        withExtendedLifetime(controller) {}
    }

    @Test("SceneAnchor publishes its route-aware authority to descendants")
    func sceneAnchorPublishesEnvironmentAuthority() {
        let (store, scenes, _) = makeSystem()
        let recorder = SceneEnvironmentProbeRecorder()
        let controller = render(
            SceneEnvironmentProbe(route: .theatre, recorder: recorder)
                .innoRouterSceneAnchor(
                    store,
                    scenes: scenes,
                    attachedTo: .theatre
                )
                .innoRouterEnvironmentMissingPolicy(.logAndDegrade)
        )

        #expect(recorder.openedPresentation != nil)
        withExtendedLifetime(controller) {}
    }

    private func makeSystem(
        policy: EnvironmentMissingPolicy = .crash
    ) -> (
        SceneStore<SceneActionsSpatialRoute>,
        SceneRegistry<SceneActionsSpatialRoute>,
        SceneRouterActions<SceneActionsSpatialRoute>
    ) {
        let store = SceneStore<SceneActionsSpatialRoute>()
        let scenes = SceneRegistry<SceneActionsSpatialRoute>(
            .window(.main, id: "main"),
            .volumetric(.model, id: "model", size: size),
            .immersive(.theatre, id: "theatre", style: .mixed)
        )
        let actions = SceneRouterActions(
            authority: makeSceneRouterAuthority(store: store, scenes: scenes),
            environmentMissingPolicy: policy
        )
        return (store, scenes, actions)
    }

    private func claimIntent(
        _ store: SceneStore<SceneActionsSpatialRoute>,
        dispatcherToken: UUID
    ) throws -> SceneIntent<SceneActionsSpatialRoute> {
        let requestID = try #require(store.currentPendingRequestID)
        return try #require(
            store.claimPendingRequest(requestID, dispatcherToken: dispatcherToken)
        )
    }

    private func claimOpen(
        _ store: SceneStore<SceneActionsSpatialRoute>,
        dispatcherToken: UUID
    ) throws -> ScenePresentation<SceneActionsSpatialRoute> {
        let intent = try claimIntent(store, dispatcherToken: dispatcherToken)
        guard case .open(let presentation) = intent else {
            Issue.record("Expected an open intent, got \(intent)")
            throw SceneActionsTestError.unexpectedIntent
        }
        let requestID = try #require(store.currentClaimedRequestID)
        _ = try #require(
            store.completeClaimedOpen(
                presentation,
                accepted: false,
                requestID: requestID
            )
        )
        return presentation
    }

    private func render<V: View>(
        _ view: V
    ) -> (window: UIWindow, controller: UIHostingController<V>) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return (window, controller)
    }
}

private enum SceneActionsTestError: Error {
    case unexpectedIntent
}

#endif
