// MARK: - SceneStoreVisionOSTests.swift
// InnoRouterPlatformTests — visionOS spatial-scene regression coverage
// Copyright © 2026 Inno Squad. All rights reserved.
//
// visionOS exposes spatial scene actions (`openWindow`,
// `openImmersiveSpace`, `dismissImmersiveSpace`, `dismissWindow`)
// through SwiftUI's environment, not through a touch event stream.
// The SceneStore + SceneHost pair translates those actions into a
// typed routing surface. These tests pin the public envelope on
// visionOS — handle accounting, ScenePresentation case shape,
// open vs dismiss vs complete lifecycle — without standing up a
// live SwiftUI view hierarchy.
//
// Surface stability: the spatial scene surface ships **experimental**
// in 4.x; see Sources/InnoRouterSwiftUI/SceneStore.swift's main
// doc comment. These tests guard the contract that ships today;
// updating them when the surface evolves is expected.

#if os(visionOS)

import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum SpatialRoute: String, Route {
    case main
    case detail
    case theatre
}

@MainActor
private func registerDispatcherHost(
    in store: SceneStore<SpatialRoute>
) -> UUID {
    let token = UUID()
    #expect(store.registerDispatcherHost(token) == true)
    return token
}

@MainActor
private func claimPendingIntent(
    in store: SceneStore<SpatialRoute>,
    dispatcherToken: UUID
) throws -> SceneIntent<SpatialRoute> {
    let requestID = try #require(store.currentPendingRequestID)
    return try #require(store.claimPendingRequest(requestID, dispatcherToken: dispatcherToken))
}

@MainActor
private func claimPendingOpen(
    in store: SceneStore<SpatialRoute>,
    dispatcherToken: UUID
) throws -> ScenePresentation<SpatialRoute> {
    let intent = try claimPendingIntent(in: store, dispatcherToken: dispatcherToken)
    guard case .open(let presentation) = intent else {
        Issue.record("Expected .open, got \(intent)")
        throw TestStoreError.unexpectedIntent
    }
    return presentation
}

private enum TestStoreError: Error {
    case unexpectedIntent
}

@Suite("visionOS spatial scene routing", .tags(.unit))
@MainActor
struct SceneStoreVisionOSTests {

    // MARK: - Window scenes

    @Test("openWindow returns a .window ScenePresentation carrying the requested route")
    func openWindow_returnsWindowCase() {
        let store = SceneStore<SpatialRoute>()
        let presentation = store.openWindow(.main)

        guard case .window(let route, _) = presentation else {
            Issue.record("Expected .window, got \(presentation)")
            return
        }
        #expect(route == .main)
    }

    @Test("openWindow allocates distinct identities for repeat opens of the same route")
    func openWindow_allocatesDistinctIdentities() {
        let store = SceneStore<SpatialRoute>()

        let first = store.openWindow(.main)
        let second = store.openWindow(.main)

        // Two .window cases for the same route must differ — otherwise
        // SwiftUI scene IDs would collide on a multi-window open.
        #expect(first != second)
    }

    // MARK: - Volumetric scenes

    @Test("openVolumetric carries the requested route and forwards the explicit size")
    func openVolumetric_carriesRouteAndSize() {
        let store = SceneStore<SpatialRoute>()
        let size = VolumetricSize(x: 1.0, y: 0.5, z: 0.5)

        let presentation = store.openVolumetric(.detail, size: size)

        guard case .volumetric(let route, let attachedSize, _) = presentation else {
            Issue.record("Expected .volumetric, got \(presentation)")
            return
        }
        #expect(route == .detail)
        #expect(attachedSize == size)
    }

    @Test("openVolumetric without an explicit size still routes to .volumetric")
    func openVolumetric_defaultSize_stillVolumetric() {
        let store = SceneStore<SpatialRoute>()

        let presentation = store.openVolumetric(.detail)

        guard case .volumetric(let route, _, _) = presentation else {
            Issue.record("Expected .volumetric, got \(presentation)")
            return
        }
        #expect(route == .detail)
    }

    // MARK: - Immersive scenes

    @Test("openImmersive(.mixed) does not crash and the store stays usable for dismiss")
    func openImmersive_mixedStyle_lifecyclePair() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)

        store.openImmersive(.theatre, style: .mixed)
        let presentation = try claimPendingOpen(in: store, dispatcherToken: token)
        store.completeOpen(presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)

        store.dismissImmersive()
        #expect(try claimPendingIntent(in: store, dispatcherToken: token) == .dismissImmersive)
        store.completeDismissal(of: presentation)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
    }

    @Test("openImmersive(.full) dispatches and dismisses without state corruption")
    func openImmersive_fullStyle_dispatchesAndDismisses() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)

        store.openImmersive(.theatre, style: .full)
        let presentation = try claimPendingOpen(in: store, dispatcherToken: token)
        store.completeOpen(presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)

        store.dismissImmersive()
        #expect(try claimPendingIntent(in: store, dispatcherToken: token) == .dismissImmersive)
        store.completeDismissal(of: presentation)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
    }

    // MARK: - Dismissal accounting

    @Test("dismissWindow + completeDismissal closes the lifecycle on the original handle")
    func dismissWindow_closesLifecycle() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)
        let presentation = store.openWindow(.main)
        #expect(try claimPendingOpen(in: store, dispatcherToken: token) == presentation)
        store.completeOpen(presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)

        store.dismissWindow(presentation)
        #expect(
            try claimPendingIntent(in: store, dispatcherToken: token) == .dismissWindow(presentation)
        )
        store.completeDismissal(of: presentation)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
    }

    @Test("completeOpen(accepted: true) acknowledges a successful environment dispatch")
    func completeOpen_acceptedTrue_doesNotCrash() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)
        let presentation = store.openWindow(.main)
        #expect(try claimPendingOpen(in: store, dispatcherToken: token) == presentation)

        store.completeOpen(presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)
        #expect(store.pendingIntent == nil)
    }

    @Test("completeOpen(accepted: false) acknowledges a refused environment dispatch")
    func completeOpen_acceptedFalse_doesNotCrash() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)
        let presentation = store.openWindow(.main)
        #expect(try claimPendingOpen(in: store, dispatcherToken: token) == presentation)

        store.completeOpen(presentation, accepted: false)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
        #expect(store.pendingIntent == nil)
    }
}

#endif
