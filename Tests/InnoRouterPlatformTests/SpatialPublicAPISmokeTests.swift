// MARK: - SpatialPublicAPISmokeTests.swift
// InnoRouterPlatformTests — visionOS public spatial API compilation
// Copyright © 2026 Inno Squad. All rights reserved.

#if os(visionOS)

import Foundation
import SwiftUI
import Testing

import InnoRouterCore
import InnoRouterSpatial

private enum SpatialPublicRoute: Route {
    case main
    case theatre
}

@SceneRouter
private enum MacroSpatialPublicRoute {
    @Scene(.window)
    case main

    @Scene(.volumetric(width: 0.6, height: 0.4, depth: 0.4))
    case model

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View {
        switch self {
        case .main:
            Text("Main")
        case .model:
            Text("Model")
        case .theatre:
            Text("Theatre")
        }
    }
}

private struct SpatialPublicActionsView: View {
    @EnvironmentSceneRouter(SpatialPublicRoute.self)
    private var scenes

    var body: some View {
        Button("Open theatre") {
            let presentation = scenes.open(.theatre)
            if let presentation {
                switch presentation {
                case .window, .volumetric:
                    scenes.dismissWindow(presentation)
                case .immersive:
                    scenes.dismissImmersive()
                }
            }
        }
    }
}

@Suite("visionOS public spatial API", .tags(.unit))
@MainActor
struct SpatialPublicAPISmokeTests {
    @Test("Consumer imports can construct the documented spatial surface")
    func documentedSurfaceCompiles() {
        _ = MacroSpatialPublicRoute.scenes

        let store = SceneStore<SpatialPublicRoute>()
        let scenes = SceneRegistry<SpatialPublicRoute>(
            .window(.main, id: "main"),
            .immersive(.theatre, id: "theatre", style: .mixed)
        )

        _ = store.openWindow(.main)
        _ = store.openImmersive(.theatre, style: .mixed)
        _ = store.events
        _ = SpatialPublicActionsView().innoRouterSceneHost(
            store,
            scenes: scenes,
            attachedTo: .main,
            instanceID: UUID()
        )
        _ = SpatialPublicActionsView().innoRouterSceneAnchor(
            store,
            scenes: scenes,
            attachedTo: .theatre
        )
    }
}

#endif
