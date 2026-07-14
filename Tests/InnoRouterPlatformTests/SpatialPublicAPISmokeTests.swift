// MARK: - SpatialPublicAPISmokeTests.swift
// InnoRouterPlatformTests — visionOS public spatial API compilation
// Copyright © 2026 Inno Squad. All rights reserved.

#if os(visionOS)

import Foundation
import SwiftUI
import Testing

import InnoRouterCore
import InnoRouterSwiftUI

private enum SpatialPublicRoute: Route {
    case main
    case theatre
}

@Suite("visionOS public spatial API", .tags(.unit))
@MainActor
struct SpatialPublicAPISmokeTests {
    @Test("Consumer imports can construct the documented spatial surface")
    func documentedSurfaceCompiles() {
        let store = SceneStore<SpatialPublicRoute>()
        let scenes = SceneRegistry<SpatialPublicRoute>(
            .window(.main, id: "main"),
            .immersive(.theatre, id: "theatre", style: .mixed)
        )

        _ = store.openWindow(.main)
        _ = store.events
        _ = EmptyView().innoRouterSceneHost(
            store,
            scenes: scenes,
            attachedTo: .main,
            instanceID: UUID()
        )
        _ = EmptyView().innoRouterSceneAnchor(
            store,
            scenes: scenes,
            attachedTo: .theatre
        )
    }
}

#endif
