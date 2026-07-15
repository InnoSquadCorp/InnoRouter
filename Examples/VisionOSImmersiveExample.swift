// MARK: - VisionOSImmersiveExample.swift
// visionOS-only macro-first scene routing example.
// Copyright © 2026 Inno Squad. All rights reserved.

// The example target ships on visionOS; other platforms compile a no-op module.
#if os(visionOS)

import SwiftUI

import InnoRouterSpatial

@SceneRouter
enum SpatialRoute {
    @Scene(.window)
    case main

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View {
        switch self {
        case .main:
            VisionOSMainView()
                .innoRouterOrnament(OrnamentAnchor(anchor: .bottom)) {
                    VisionOSControlBar()
                }
        case .theatre:
            VisionOSTheatreView()
        }
    }
}

/// Installing the generated scene tree is the only app-level wiring required.
@main
struct VisionOSImmersiveExampleApp: App {
    var body: some Scene {
        SpatialRoute.scenes
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
    @EnvironmentSceneRouter(SpatialRoute.self) private var scenes

    var body: some View {
        HStack(spacing: 16) {
            Button("Enter Theatre") {
                scenes.open(.theatre)
            }
            Button("Leave Theatre") {
                scenes.dismissImmersive()
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
