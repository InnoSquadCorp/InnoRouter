import Foundation
import Testing

import InnoRouter
import InnoRouterTesting

/// Captured callbacks retain useful observations without claiming that runtime
/// authority can be reconstructed. Explicitly authored fixtures are separate.
@MainActor
func assertCapturedReplayUnsupported<R: Route & Codable>(
    _ fixture: RouterScenarioFixture<R>,
    code: RouterScenarioReplayLimitation
) async throws {
    #expect(fixture.completeness.isComplete)
    #expect(fixture.steps.first?.replayLimitation == code)
    let decoded = try RouterScenarioFixture<R>.decode(from: JSONEncoder().encode(fixture))
    #expect(decoded == fixture)
    #expect(throws: RouterScenarioSourceGenerationError.unsupportedRequestSemantics(step: 0, code: code)) {
        _ = try RouterScenarioSourceGenerator.generate(decoded, routeTypeName: "AuthoredRoute")
    }
    #expect(throws: RouterScenarioSourceGenerationError.unsupportedRequestSemantics(step: 0, code: code)) {
        _ = try RouterScenarioSourceGenerator.generateFiles(decoded, routeTypeName: "AuthoredRoute")
    }
    let target = RouterTestStore<R>(initialState: decoded.initialState, exhaustivity: .off)
    await #expect(throws: RouterScenarioReplayError.unsupportedRequestSemantics(step: 0, code: code)) {
        _ = try await RouterScenarioRunner.replay(decoded, on: target)
    }
    #expect(target.state == decoded.initialState)
    #expect(target.revision == 0)
    await target.finish()
}
