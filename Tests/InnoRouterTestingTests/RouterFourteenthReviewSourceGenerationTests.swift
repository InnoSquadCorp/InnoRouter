import Testing

import InnoRouter
import InnoRouterTesting

private enum FourteenthReviewGeneratorRoute: String, Route, Codable {
    case route
}

@Suite("Fourteenth review source generation regressions")
struct RouterFourteenthReviewSourceGenerationTests {
    @Test("Discard identifiers are rejected in every generated declaration position")
    func rejectsDiscardIdentifier() throws {
        let fixture = RouterScenarioFixture<FourteenthReviewGeneratorRoute>(
            initialState: .rootStack,
            steps: [],
            completeness: .init()
        )
        #expect(throws: RouterScenarioSourceGenerationError.invalidSwiftIdentifier("_")) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "FourteenthReviewGeneratorRoute",
                testName: "_"
            )
        }
        #expect(throws: RouterScenarioSourceGenerationError.invalidSwiftIdentifier("_")) {
            _ = try RouterScenarioSourceGenerator.generateFiles(
                fixture,
                routeTypeName: "FourteenthReviewGeneratorRoute",
                storeFactory: "_"
            )
        }
        #expect(throws: RouterScenarioSourceGenerationError.invalidSwiftIdentifier("Module._")) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "Module._"
            )
        }
        #expect(throws: RouterScenarioSourceGenerationError.invalidSwiftIdentifier("_.factory")) {
            _ = try RouterScenarioSourceGenerator.generate(
                fixture,
                routeTypeName: "FourteenthReviewGeneratorRoute",
                featureResolversFactory: "_.factory"
            )
        }
        #expect(throws: RouterScenarioSourceGenerationError.invalidSwiftIdentifier("Module._")) {
            _ = try RouterScenarioSourceGenerator.generateFiles(
                fixture,
                routeTypeName: "FourteenthReviewGeneratorRoute",
                environmentFactory: "Module._"
            )
        }

        _ = try RouterScenarioSourceGenerator.generate(
            fixture,
            routeTypeName: "FourteenthReviewGeneratorRoute",
            testName: "_captured",
            storeFactory: "Module._store",
            featureResolversFactory: "Module._features"
        )
        _ = try RouterScenarioSourceGenerator.generateFiles(
            fixture,
            routeTypeName: "FourteenthReviewGeneratorRoute",
            testName: "_captured",
            storeFactory: "Module._store",
            environmentFactory: "Module._environment",
            featureResolversFactory: "Module._features"
        )
    }
}
