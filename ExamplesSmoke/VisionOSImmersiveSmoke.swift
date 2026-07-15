#if os(visionOS)
import SwiftUI

import InnoRouterSpatial

@SceneRouter
enum VisionOSSmokeRoute {
    @Scene(.window)
    case main

    @Scene(.volumetric(width: 0.6, height: 0.4, depth: 0.4))
    case model

    @Scene(.immersive(style: .mixed))
    case theatre

    var destination: some View {
        switch self {
        case .main:
            VisionOSSmokeSceneActions()
        case .model:
            Text("Model")
        case .theatre:
            Text("Theatre")
        }
    }
}

private struct VisionOSSmokeSceneActions: View {
    @EnvironmentSceneRouter(VisionOSSmokeRoute.self) private var scenes

    var body: some View {
        VStack {
            Button("Open model") {
                if let presentation = scenes.open(.model) {
                    scenes.dismissWindow(presentation)
                }
            }
            Button("Enter theatre") {
                scenes.open(.theatre)
            }
            Button("Leave theatre") {
                scenes.dismissImmersive()
            }
        }
    }
}

@MainActor
func visionOSImmersiveSmoke() {
    _ = VisionOSSmokeRoute.scenes

    // Ornament modifier is cross-platform; reference it here to keep
    // the symbol exercised in the smoke target.
    _ = EmptyView().innoRouterOrnament(OrnamentAnchor(anchor: .bottom)) {
        Text("Ornament")
    }
}
#endif
