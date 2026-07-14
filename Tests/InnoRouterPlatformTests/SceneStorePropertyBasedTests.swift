// MARK: - SceneStorePropertyBasedTests.swift
// InnoRouterPlatformTests — SceneStore invariant probing via parametric tests
// Copyright © 2026 Inno Squad. All rights reserved.

#if os(visionOS)

import Foundation
import Testing

import InnoRouterCore
@testable import InnoRouterSwiftUI

private enum SpatialRoute: String, Route {
    case main
    case theatre
}

@Suite("SceneStore property-based scenarios", .tags(.unit))
@MainActor
struct SceneStorePropertyBasedTests {

    @Test(
        "openWindow / dismissWindow round-trips do not corrupt SceneStore state",
        arguments: 1...32
    )
    func openDismissRoundTrip(seed: Int) throws {
        var state = SceneStoreState<SpatialRoute>()
        let length = seed + 4

        for index in 0..<length {
            let window = ScenePresentation<SpatialRoute>.window(
                .main,
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            )

            #expect(state.requestOpen(window).isEmpty)
            let openRequestID = try #require(state.currentPendingRequestID)
            #expect(state.claimPendingRequest(openRequestID) == .open(window))
            #expect(
                state.completeOpen(
                    window,
                    accepted: true,
                    requestID: openRequestID
                ) == .broadcast(.presented(window))
            )
            #expect(state.activeScenes.contains(window))

            #expect(state.requestDismissWindow(window).isEmpty)
            let dismissRequestID = try #require(state.currentPendingRequestID)
            #expect(state.claimPendingRequest(dismissRequestID) == .dismissWindow(window))
            #expect(
                state.completeDismissal(
                    of: window,
                    requestID: dismissRequestID
                ) == .broadcast(.dismissed(window))
            )
            #expect(state.activeScenes.contains(window) == false)
        }

        #expect(state.activeScenes.isEmpty)
        #expect(state.pendingIntent == nil)
        #expect(state.currentPendingRequestID == nil)
    }

    @Test("Repeated immersive opens stay single-occupancy")
    func repeatedImmersive_singleSlot() throws {
        let store = SceneStore<SpatialRoute>()

        for _ in 0..<5 {
            store.openImmersive(.theatre, style: .mixed)
        }

        let pending = try #require(store.pendingIntent)
        guard case .open(.immersive(.theatre, style: .mixed, id: _)) = pending else {
            Issue.record("Expected pending immersive open, got \(pending)")
            return
        }
    }
}

#endif
