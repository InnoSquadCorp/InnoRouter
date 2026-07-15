// MARK: - SceneRouterBehaviorTests.swift
// InnoRouterMacrosBehaviorTests - @SceneRouter runtime composition
// Copyright © 2026 Inno Squad. All rights reserved.

#if canImport(InnoRouterMacrosPlugin)

import SwiftUI
import Testing

import InnoRouterSpatial

@SceneRouter
private enum BehaviorSceneRoute {
    @Scene(.window)
    case main

    @Scene(
        .volumetric(width: 0.6, height: 0.4, depth: 0.4),
        id: "model-space"
    )
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

@Suite("@SceneRouter behavior")
struct SceneRouterBehaviorTests {
    @Test("Every scene style compiles and builds through the generated destination witness")
    @MainActor
    func generatedDestinationRouteConformance() {
        let routes: [BehaviorSceneRoute] = [.main, .model, .theatre]

        for route in routes {
            _ = BehaviorSceneRoute.destination(for: route)
        }

        #expect(Set(routes).count == 3)
    }
}

#endif
