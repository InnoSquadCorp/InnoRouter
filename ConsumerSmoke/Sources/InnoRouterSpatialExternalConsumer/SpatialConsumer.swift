#if os(visionOS)
import SwiftUI

import InnoRouterSpatial

@SceneRouter
enum ExternalSceneRoute {
    @Scene(.window)
    case main

    @Scene(.volumetric(width: 0.6, height: 0.4, depth: 0.4))
    case model

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View {
        switch self {
        case .main:
            ExternalSceneActions()
        case .model:
            Text("Model")
        case .theatre:
            Text("Theatre")
        }
    }
}

private struct ExternalSceneActions: View {
    @EnvironmentSceneRouter(ExternalSceneRoute.self) private var scenes

    var body: some View {
        Button("Open model") {
            scenes.open(.model)
        }
        Button("Enter theatre") {
            scenes.open(.theatre)
        }
        Button("Leave theatre") {
            scenes.dismissImmersive()
        }
    }
}

@MainActor
public enum SpatialConsumerProbe {
    public static func exercise() {
        _ = ExternalSceneRoute.scenes
        _ = EmptyView().innoRouterOrnament(OrnamentAnchor(anchor: .bottom)) {
            Text("Ornament")
        }
    }
}
#endif
