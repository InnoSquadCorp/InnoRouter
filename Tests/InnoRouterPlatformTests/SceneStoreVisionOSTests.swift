// MARK: - SceneStoreVisionOSTests.swift
// InnoRouterPlatformTests — visionOS spatial-scene regression coverage
// Copyright © 2026 Inno Squad. All rights reserved.
//
// visionOS exposes spatial scene actions (`openWindow`,
// `openImmersiveSpace`, `dismissImmersiveSpace`, `dismissWindow`)
// through SwiftUI's environment, not through a touch event stream.
// The SceneStore + SceneHost pair translates those actions into a
// typed routing surface. These tests exercise internal request claiming
// and completion so handle accounting and lifecycle transitions remain
// deterministic without standing up a live SwiftUI view hierarchy.
// Public consumer compilation is covered separately by
// SpatialPublicAPISmokeTests.

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

@MainActor
private func completeClaimedOpen(
    in store: SceneStore<SpatialRoute>,
    presentation: ScenePresentation<SpatialRoute>,
    accepted: Bool
) throws {
    let requestID = try #require(store.currentClaimedRequestID)
    _ = try #require(
        store.completeClaimedOpen(
            presentation,
            accepted: accepted,
            requestID: requestID
        )
    )
}

@MainActor
private func completeClaimedDismissal(
    in store: SceneStore<SpatialRoute>,
    presentation: ScenePresentation<SpatialRoute>
) throws {
    let requestID = try #require(store.currentClaimedRequestID)
    _ = try #require(
        store.completeClaimedDismissal(
            of: presentation,
            requestID: requestID
        )
    )
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
        try completeClaimedOpen(in: store, presentation: presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)

        store.dismissImmersive()
        #expect(try claimPendingIntent(in: store, dispatcherToken: token) == .dismissImmersive)
        try completeClaimedDismissal(in: store, presentation: presentation)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
    }

    @Test("openImmersive(.full) dispatches and dismisses without state corruption")
    func openImmersive_fullStyle_dispatchesAndDismisses() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)

        store.openImmersive(.theatre, style: .full)
        let presentation = try claimPendingOpen(in: store, dispatcherToken: token)
        try completeClaimedOpen(in: store, presentation: presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)

        store.dismissImmersive()
        #expect(try claimPendingIntent(in: store, dispatcherToken: token) == .dismissImmersive)
        try completeClaimedDismissal(in: store, presentation: presentation)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
    }

    // MARK: - Dismissal accounting

    @Test("dismissWindow closes the lifecycle on the original handle")
    func dismissWindow_closesLifecycle() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)
        let presentation = store.openWindow(.main)
        #expect(try claimPendingOpen(in: store, dispatcherToken: token) == presentation)
        try completeClaimedOpen(in: store, presentation: presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)

        store.dismissWindow(presentation)
        #expect(
            try claimPendingIntent(in: store, dispatcherToken: token) == .dismissWindow(presentation)
        )
        try completeClaimedDismissal(in: store, presentation: presentation)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
    }

    @Test("Accepted open dispatch commits the claimed presentation")
    func acceptedOpenCommitsClaimedPresentation() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)
        let presentation = store.openWindow(.main)
        #expect(try claimPendingOpen(in: store, dispatcherToken: token) == presentation)

        try completeClaimedOpen(in: store, presentation: presentation, accepted: true)

        #expect(store.activeScenes == [presentation])
        #expect(store.currentScene == presentation)
        #expect(store.currentPendingRequestID == nil)
        #expect(store.currentClaimedRequestID == nil)
    }

    @Test("Rejected open dispatch releases the claim without changing inventory")
    func rejectedOpenReleasesClaim() throws {
        let store = SceneStore<SpatialRoute>()
        let token = registerDispatcherHost(in: store)
        let presentation = store.openWindow(.main)
        #expect(try claimPendingOpen(in: store, dispatcherToken: token) == presentation)

        try completeClaimedOpen(in: store, presentation: presentation, accepted: false)

        #expect(store.activeScenes.isEmpty)
        #expect(store.currentScene == nil)
        #expect(store.currentPendingRequestID == nil)
        #expect(store.currentClaimedRequestID == nil)
    }
}

#endif
