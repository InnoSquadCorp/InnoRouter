import Foundation

import InnoRouterCore
import InnoRouterInspector
import InnoRouterSwiftUI

@MainActor
private final class RouterScenarioInspectorStorage<R: Route & Codable> {
    let store: RouterStore<R>
    let capacity: Int
    let metadata: RouterScenarioMetadata?
    var recorder: RouterScenarioRecorder<R>?

    init(store: RouterStore<R>, capacity: Int, metadata: RouterScenarioMetadata?) {
        self.store = store
        self.capacity = capacity
        self.metadata = metadata
    }
}

public extension RouterInspectorScenarioController {
    /// Standard opt-in bridge between the payload-free Inspector controls and
    /// the raw scenario fixture recorder in `InnoRouterTesting`.
    static func routerScenario<R: Route & Codable>(
        store: RouterStore<R>,
        capacity: Int = 256,
        metadata: RouterScenarioMetadata? = nil
    ) -> RouterInspectorScenarioController {
        let capacity = max(1, capacity)
        let storage = RouterScenarioInspectorStorage(
            store: store,
            capacity: capacity,
            metadata: metadata
        )
        return RouterInspectorScenarioController(
            capacity: capacity,
            start: {
                storage.recorder = RouterScenarioRecorder(
                    store: storage.store,
                    capacity: storage.capacity,
                    metadata: storage.metadata
                )
            },
            stop: {
                guard let recorder = storage.recorder else {
                    return .init(status: .failed, capturedStepCount: 0, summary: "not-recording")
                }
                let fixture = recorder.stop()
                storage.recorder = nil
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(fixture)
                let completeness = fixture.completeness
                let status: RouterInspectorScenarioStatus = completeness.isComplete
                    ? .complete
                    : .incomplete
                let summary = completeness.isComplete
                    ? "complete"
                    : "unpaired=\(completeness.unpairedRequestCount),dropped=\(completeness.droppedStepCount),missingExpectations=\(completeness.missingExpectationCount),missingControls=\(completeness.missingControlCount)"
                return .init(
                    status: status,
                    capturedStepCount: fixture.steps.count,
                    summary: summary,
                    rawFixtureData: data
                )
            },
            currentStepCount: { storage.recorder?.steps.count ?? 0 },
            importFixture: { data in
                let fixture = try RouterScenarioFixture<R>.decode(from: data)
                let completeness = fixture.completeness
                return .init(
                    status: completeness.isComplete ? .complete : .incomplete,
                    capturedStepCount: fixture.steps.count,
                    summary: completeness.isComplete
                        ? "complete"
                        : "unpaired=\(completeness.unpairedRequestCount),dropped=\(completeness.droppedStepCount),missingExpectations=\(completeness.missingExpectationCount),missingControls=\(completeness.missingControlCount)",
                    rawFixtureData: data
                )
            }
        )
    }
}
