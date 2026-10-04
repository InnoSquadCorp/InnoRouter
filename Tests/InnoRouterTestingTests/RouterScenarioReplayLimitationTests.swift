import Foundation
import Testing

import InnoRouter
import InnoRouterTesting

private enum LimitationRoute: String, Route, Codable {
    case home
    case detail
}

@Suite("Scenario runtime authority limitations")
@MainActor
struct RouterScenarioReplayLimitationTests {
    @Test("Ordinary same-state apply remains replayable")
    func ordinaryApplyControl() async throws {
        let source = RouterStore<LimitationRoute>()
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.apply(.init(state: source.state)))
        let fixture = try complete(recorder.stop())
        #expect(fixture.steps.count == 1)
        #expect(fixture.steps[0].replayLimitation == nil)
        let target = try RouterTestStore<LimitationRoute>(exhaustivity: .off)
        _ = try await RouterScenarioRunner.replay(fixture, on: target)
        #expect(target.revision == 0)
        await target.finish()
    }

    @Test("Exact restore and subtree replacement cannot become ordinary apply", arguments: [false, true])
    func replacementFailsClosed(restore: Bool) async throws {
        let source = RouterStore<LimitationRoute>()
        let recorder = RouterScenarioRecorder(store: source)
        if restore {
            let codec = try RouterSnapshotCodec<LimitationRoute>(currentVersion: 1)
            _ = try await source.restore(from: codec.encode(source.state), using: codec)
        } else {
            _ = await source.replaceSubtree(with: source.state.root)
        }
        let fixture = try complete(recorder.stop())
        #expect(fixture.steps.count == 1)
        try await assertUnsupported(fixture, code: .runtimeOwnershipReplacement)
    }

    @Test("Scope callback authority is never recreated from a captured action")
    func scopedRequestFailsClosed() async throws {
        let source = RouterStore<LimitationRoute>()
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.scope().perform(.push(.detail))
        try await assertUnsupported(complete(recorder.stop()), code: .runtimeExecutionPrecondition)
    }

    @Test("Configured runtime authorization is explicit in replay limitations")
    func authorizationFailsClosed() async throws {
        let source = try RouterStore<LimitationRoute>(configuration: .init(
            authorization: .init(requiresAuthorization: { _ in true }, authorize: { true })
        ))
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.detail))
        try await assertUnsupported(complete(recorder.stop()), code: .runtimeAuthorization)
    }

    @Test("Unknown limitation codes survive transport and reject replay before mutation")
    func unknownCodeFailsClosed() async throws {
        let code = RouterScenarioReplayLimitation(rawValue: "future.unsupportedAuthority")
        let state = RouterState<LimitationRoute>.rootStack
        let step = RouterScenarioStep(
            action: RouterAction<LimitationRoute>.push(.detail),
            context: .init(),
            replayLimitation: code,
            observedState: state,
            observedRevision: 0,
            observedTerminal: .unchanged,
            expectation: .init(state: state, revision: 0, terminal: .unchanged)
        )
        try await assertUnsupported(.init(initialState: state, steps: [step]), code: code)
    }

    @Test("Known formats require an explicit limitation field, including null")
    func missingFieldAndOldFormatFailClosed() async throws {
        let source = RouterStore<LimitationRoute>()
        let recorder = RouterScenarioRecorder(store: source)
        _ = await source.perform(.push(.home))
        let fixture = try complete(recorder.stop())
        let encoded = try JSONEncoder().encode(fixture)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var steps = try #require(object["steps"] as? [[String: Any]])
        #expect(steps[0]["replayLimitation"] is NSNull)
        steps[0].removeValue(forKey: "replayLimitation")
        object["steps"] = steps
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try RouterScenarioFixture<LimitationRoute>.decode(from: missing)
        }
        object["formatVersion"] = 7
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: RouterScenarioFixtureError.unsupportedFormatVersion(7)) {
            _ = try RouterScenarioFixture<LimitationRoute>.decode(from: old)
        }
    }

    private func complete(
        _ fixture: RouterScenarioFixture<LimitationRoute>
    ) throws -> RouterScenarioFixture<LimitationRoute> {
        try fixture.settingExpectations(fixture.steps.map {
            .init(state: $0.observedState, revision: $0.observedRevision,
                  terminal: $0.observedTerminal, rejection: $0.observedRejection)
        })
    }

    private func assertUnsupported(
        _ fixture: RouterScenarioFixture<LimitationRoute>,
        code: RouterScenarioReplayLimitation
    ) async throws {
        #expect(fixture.completeness.isComplete)
        #expect(fixture.steps.first?.replayLimitation == code)
        let data = try JSONEncoder().encode(fixture)
        let decoded = try RouterScenarioFixture<LimitationRoute>.decode(from: data)
        #expect(decoded == fixture)
        #expect(decoded.steps.first?.replayLimitation == code)
        #expect(throws: RouterScenarioSourceGenerationError.unsupportedRequestSemantics(step: 0, code: code)) {
            _ = try RouterScenarioSourceGenerator.generate(decoded, routeTypeName: "LimitationRoute")
        }
        #expect(throws: RouterScenarioSourceGenerationError.unsupportedRequestSemantics(step: 0, code: code)) {
            _ = try RouterScenarioSourceGenerator.generateFiles(decoded, routeTypeName: "LimitationRoute")
        }
        let target = try RouterTestStore<LimitationRoute>(initialState: fixture.initialState, exhaustivity: .off)
        await #expect(throws: RouterScenarioReplayError.unsupportedRequestSemantics(step: 0, code: code)) {
            _ = try await RouterScenarioRunner.replay(decoded, on: target)
        }
        #expect(target.state == fixture.initialState)
        #expect(target.revision == 0)
        await target.finish()
    }
}
