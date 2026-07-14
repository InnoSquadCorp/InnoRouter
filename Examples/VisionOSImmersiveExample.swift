// MARK: - VisionOSImmersiveExample.swift
// visionOS-only example demonstrating SceneStore, SceneHost, and the
// cross-platform `.innoRouterOrnament` view modifier.
// Copyright © 2026 Inno Squad. All rights reserved.

// MARK: - Platform: The SceneStore / SceneHost pair is visionOS-only.
// The example target that builds this file ships on visionOS; other
// platforms compile a no-op module.
#if os(visionOS)

import SwiftUI

import InnoRouter
import InnoRouterSpatial

enum SpatialRoute: String, Route {
    case main
    case theatre
}

/// Example `App` that opens a regular window for the main surface, an
/// ornament-anchored controls panel, and an immersive space for the
/// theatre route.
@main
struct VisionOSImmersiveExampleApp: App {
    @State private var sceneStore = SceneStore<SpatialRoute>()
    private let scenes: SceneRegistry<SpatialRoute> = .init(
        .window(.main, id: SpatialRoute.main.rawValue),
        .immersive(.theatre, id: SpatialRoute.theatre.rawValue, style: .mixed)
    )

    var body: some Scene {
        // The main WindowGroup is the SceneHost's home — exactly one
        // SceneHost per store handles every open/dismiss through
        // SwiftUI's environment actions. Attach ornaments here but NOT
        // a SceneAnchor: the host already owns this scene.
        WindowGroup(id: SpatialRoute.main.rawValue, for: UUID.self) { $sceneID in
            VisionOSMainView()
                .innoRouterOrnament(OrnamentAnchor(anchor: .bottom)) {
                    VisionOSControlBar(store: sceneStore)
                }
                .innoRouterSceneHost(
                    sceneStore,
                    scenes: scenes,
                    attachedTo: .main,
                    instanceID: sceneID
                )
        } defaultValue: {
            UUID()
        }

        // Every non-host scene needs a SceneAnchor so its system-driven
        // appear/disappear transitions stay in sync with SceneStore's
        // inventory. Fallback opening is limited to the same scene,
        // but dismissals are handled for any scene while the host scene
        // is gone.
        ImmersiveSpace(id: SpatialRoute.theatre.rawValue) {
            VisionOSTheatreView()
                .innoRouterSceneAnchor(
                    sceneStore,
                    scenes: scenes,
                    attachedTo: .theatre
                )
        }
    }
}

struct VisionOSMainView: View {
    var body: some View {
        Text("InnoRouter visionOS")
            .font(.largeTitle)
            .padding(64)
    }
}

struct VisionOSControlBar: View {
    @Bindable var store: SceneStore<SpatialRoute>

    var body: some View {
        HStack(spacing: 16) {
            Button("Enter Theatre") {
                store.openImmersive(.theatre, style: .mixed)
            }
            Button("Leave Theatre") {
                store.dismissImmersive()
            }
        }
        .padding()
        .glassBackgroundEffect()
    }
}

struct VisionOSTheatreView: View {
    var body: some View {
        Text("Immersive theatre content")
    }
}

#endif
