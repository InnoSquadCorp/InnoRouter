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
            Text("Main")
        case .model:
            Text("Model")
        case .theatre:
            Text("Theatre")
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
