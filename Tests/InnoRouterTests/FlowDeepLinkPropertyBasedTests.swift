// MARK: - FlowDeepLinkPropertyBasedTests.swift
// InnoRouterTests - seed-parameterised invariants on composite deep-link replay
// Copyright © 2026 Inno Squad. All rights reserved.

import Testing
import Foundation
import Synchronization
import InnoRouter
import InnoRouterSwiftUI
import InnoRouterDeepLink
import InnoRouterEffects

@Suite("FlowDeepLink property-based tests")
struct FlowDeepLinkPropertyBasedTests {
    @Test(
        "FlowDeepLinkPipeline decisions match the closed URL grammar model",
        arguments: Array(0..<80)
    )
    @MainActor
    func pipelineDecisionMatchesModel(seed: Int) {
        var rng = PropertyPBTGenerator(seed: seed)
        let auth = Mutex(false)
        let pipeline = makePropertyFlowPipeline(
            isAuthenticated: { auth.withLock { $0 } }
        )

        for step in 0..<20 {
            let isAuthenticated = rng.nextBool()
            auth.withLock { $0 = isAuthenticated }
            let urlCase = rng.nextURLCase()

            let actual = pipeline.decide(for: urlCase.url)
            let expected = urlCase.modelDecision(isAuthenticated: isAuthenticated)

            if actual != expected {
                Issue.record(
                    "seed \(seed) step \(step): pipeline decision mismatch for \(urlCase). expected \(expected), got \(actual)"
                )
            }
        }
    }

    @Test(
        "FlowDeepLink replay state machine matches the reference model",
        arguments: Array(0..<60)
    )
    @MainActor
    func replayStateMachineMatchesModel(seed: Int) async {
        var rng = PropertyPBTGenerator(seed: seed)
        let initialAuth = rng.nextBool()
        let auth = Mutex(initialAuth)
        let pipeline = makePropertyFlowPipeline(
            isAuthenticated: { auth.withLock { $0 } }
        )
        let store = FlowStore<PropertyRoute>()
        let handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: store
        )
        var model = DeepLinkReplayModelState(isAuthenticated: initialAuth)

        for step in 0..<18 {
            let action = rng.nextReplayAction()
            let expected = model.apply(action)
            let actual: FlowDeepLinkEffectHandler<PropertyRoute>.Result?

            switch action {
            case .handle(let urlCase):
                actual = handler.handle(urlCase.url)
            case .resumePending:
                actual = handler.resumePendingDeepLink()
            case .resumePendingIfAllowed(let allow):
                actual = await handler.resumePendingDeepLinkIfAllowed { _ in allow }
            case .setAuthenticated(let isAuthenticated):
                auth.withLock { $0 = isAuthenticated }
                actual = nil
            case .clearPending:
                handler.clearPendingDeepLink()
                actual = nil
            }

            if actual != expected {
                Issue.record(
                    "seed \(seed) step \(step): replay result mismatch for \(action). expected \(String(describing: expected)), got \(String(describing: actual))"
                )
            }

            if handler.pendingDeepLink != model.pendingDeepLink {
                Issue.record(
                    "seed \(seed) step \(step): pending deep link mismatch. expected \(String(describing: model.pendingDeepLink)), got \(String(describing: handler.pendingDeepLink))"
                )
            }

            if store.path != model.flowState.path {
                Issue.record(
                    "seed \(seed) step \(step): flow path mismatch after \(action). expected \(model.flowState.path), got \(store.path)"
                )
            }
        }
    }

    @Test(
        "Successful deep-link apply emits the same normalized event shape as direct FlowStore.reset",
        arguments: Array(0..<60)
    )
    @MainActor
    func successfulHandleMatchesDirectResetEventShape(seed: Int) async {
        var rng = PropertyPBTGenerator(seed: seed)
        let urlCase = rng.nextHandledURLCase()
        let auth = Mutex(true)
        let pipeline = makePropertyFlowPipeline(
            isAuthenticated: { auth.withLock { $0 } }
        )

        let handledStore = FlowStore<PropertyRoute>()
        let handledRecorder = FlowEventRecorder(store: handledStore)
        defer { handledRecorder.cancel() }

        let handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: handledStore
        )

        let handledMarker = handledRecorder.mark()
        let handledResult = handler.handle(urlCase.url)
        let handledEvents = (
            await handledRecorder.rawEvents(
                since: handledMarker,
                minimumCount: 1
            )
        ).compactMap(normalizeFlowEvent)

        guard case .executed(let plan, let path) = handledResult else {
            Issue.record("seed \(seed): expected .executed for \(urlCase), got \(handledResult)")
            return
        }

        let directStore = FlowStore<PropertyRoute>()
        let directRecorder = FlowEventRecorder(store: directStore)
        defer { directRecorder.cancel() }

        let directMarker = directRecorder.mark()
        directStore.send(.reset(plan.steps))
        let directEvents = (
            await directRecorder.rawEvents(
                since: directMarker,
                minimumCount: 1
            )
        ).compactMap(normalizeFlowEvent)

        if normalizedFlowEventMultiset(handledEvents) != normalizedFlowEventMultiset(directEvents) {
            Issue.record(
                "seed \(seed): deep-link event signature mismatch for \(urlCase). handler \(handledEvents), direct \(directEvents)"
            )
        }

        if path != directStore.path {
            Issue.record(
                "seed \(seed): resulting path mismatch for \(urlCase). handler \(path), direct \(directStore.path)"
            )
        }
    }

    @Test(
        "Pending, rejected, and unhandled deep links do not emit flow mutation events",
        arguments: Array(0..<40)
    )
    @MainActor
    func nonApplyingDecisionsEmitNoFlowMutationEvents(seed: Int) async {
        var rng = PropertyPBTGenerator(seed: seed)
        let auth = Mutex(false)
        let pipeline = makePropertyFlowPipeline(
            isAuthenticated: { auth.withLock { $0 } }
        )
        let store = FlowStore<PropertyRoute>()
        let recorder = FlowEventRecorder(store: store)
        defer { recorder.cancel() }

        let nonApplying: [PropertyURLCase] = [
            .unknown,
            .badSchemeHome,
            .badHostHome,
            .secure,
            .homeSecure
        ]

        for step in 0..<10 {
            let urlCase = nonApplying[rng.nextInt(upperBound: nonApplying.count)]
            let marker = recorder.mark()
            let oldPath = store.path

            let result = handlerResult(
                for: urlCase,
                pipeline: pipeline,
                store: store
            )
            let events = (await recorder.rawEvents(since: marker)).compactMap(normalizeFlowEvent)

            if !events.isEmpty {
                Issue.record(
                    "seed \(seed) step \(step): expected no flow mutation events for \(urlCase), got \(events)"
                )
            }

            if store.path != oldPath {
                Issue.record(
                    "seed \(seed) step \(step): non-applying deep link mutated path for \(urlCase). old \(oldPath), new \(store.path)"
                )
            }

            switch urlCase {
            case .secure, .homeSecure:
                guard case .pending = result else {
                    Issue.record("seed \(seed) step \(step): expected pending result for \(urlCase), got \(result)")
                    continue
                }
            case .unknown:
                guard case .unhandled = result else {
                    Issue.record("seed \(seed) step \(step): expected unhandled result for \(urlCase), got \(result)")
                    continue
                }
            case .badSchemeHome, .badHostHome:
                guard case .rejected = result else {
                    Issue.record("seed \(seed) step \(step): expected rejected result for \(urlCase), got \(result)")
                    continue
                }
            default:
                // nonApplying currently contains only the five cases above; keep
                // this fallback as a guard if PropertyURLCase grows later.
                Issue.record("seed \(seed) step \(step): unexpected URL case \(urlCase)")
            }
        }
    }

    @MainActor
    private func handlerResult(
        for urlCase: PropertyURLCase,
        pipeline: FlowDeepLinkPipeline<PropertyRoute>,
        store: FlowStore<PropertyRoute>
    ) -> FlowDeepLinkEffectHandler<PropertyRoute>.Result {
        let handler = FlowDeepLinkEffectHandler(
            pipeline: pipeline,
            applier: store
        )
        return handler.handle(urlCase.url)
    }
}
