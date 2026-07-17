#if os(visionOS)
import Foundation
import Testing

import InnoRouterCore
import InnoRouterSpatial
import InnoRouterSpatialExternalConsumer

private enum ConsumerTestRoute: Route {
    case main
    case theatre
}

@Suite("External visionOS consumer", .serialized)
@MainActor
struct SpatialConsumerTests {
    @Test("Macro-first product links and exposes the public runtime")
    func productLinksAndRuns() {
        SpatialConsumerProbe.exercise()

        let store = SceneStore<ConsumerTestRoute>()
        let scenes = SceneRegistry<ConsumerTestRoute>(
            .window(.main, id: "main"),
            .immersive(.theatre, id: "theatre", style: .mixed)
        )

        _ = store.openWindow(.main)
        _ = scenes
    }
}
#endif
