import Foundation

import InnoRouterCore

public enum RouterScenarioSourceGenerationError: Error, Hashable, Sendable {
    case incomplete(RouterScenarioCompleteness)
    case invalidEventOrdering
    case invalidExpectedRevision(step: Int)
    case missingCancellationProvenance(step: Int)
    case unsupportedHistoryLifetime(step: Int)
    case invalidSwiftIdentifier(String)
    case encodingFailed
    case invalidFixtureFileName(String)
}

public struct RouterScenarioGeneratedFiles: Hashable, Sendable {
    public let source: String
    public let fixtureData: Data
    public let fixtureFileName: String

    public init(source: String, fixtureData: Data, fixtureFileName: String) {
        self.source = source
        self.fixtureData = fixtureData
        self.fixtureFileName = fixtureFileName
    }
}

public enum RouterScenarioSourceGenerator {
    /// Emits an executable Swift Testing source plus a separate, reviewable
    /// JSON fixture. Place both files in the same test-source directory.
    public static func generateFiles<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        routeTypeName: String,
        fixtureFileName: String = "router-scenario.json",
        testName: String = "capturedRouterScenario",
        storeFactory: String = "makeRouterTestStore",
        environmentFactory: String = "makeRouterScenarioEnvironment"
    ) throws -> RouterScenarioGeneratedFiles {
        try validate(
            fixture,
            routeTypeName: routeTypeName,
            testName: testName,
            storeFactory: storeFactory
        )
        guard isQualifiedSwiftName(environmentFactory) else {
            throw RouterScenarioSourceGenerationError.invalidSwiftIdentifier(environmentFactory)
        }
        guard isSafeFixtureFileName(fixtureFileName) else {
            throw RouterScenarioSourceGenerationError.invalidFixtureFileName(fixtureFileName)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(fixture) else {
            throw RouterScenarioSourceGenerationError.encodingFailed
        }
        let source = """
        import Foundation
        import Testing
        import InnoRouter
        import InnoRouterTesting

        @Test("Captured InnoRouter scenario")
        @MainActor
        func \(testName)() async throws {
            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("\(fixtureFileName)")
            let fixture = try RouterScenarioFixture<\(routeTypeName)>.decode(
                from: Data(contentsOf: fixtureURL)
            )
            let store = \(storeFactory)(fixture.initialState)
            let environment = \(environmentFactory)()
            do {
                _ = try await RouterScenarioRunner.replay(
                    fixture,
                    on: store,
                    environment: environment
                )
                store.skipReceivedEvents()
                await store.finish()
            } catch {
                store.skipReceivedEvents()
                await store.finish()
                throw error
            }
        }
        """
        return RouterScenarioGeneratedFiles(
            source: source,
            fixtureData: data,
            fixtureFileName: fixtureFileName
        )
    }

    /// Emits a standalone Swift Testing source file. The caller supplies a
    /// factory that recreates production policies around the captured state.
    public static func generate<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        routeTypeName: String,
        testName: String = "capturedRouterScenario",
        storeFactory: String = "makeRouterTestStore"
    ) throws -> String {
        try validate(
            fixture,
            routeTypeName: routeTypeName,
            testName: testName,
            storeFactory: storeFactory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(fixture) else {
            throw RouterScenarioSourceGenerationError.encodingFailed
        }
        let encoded = data.base64EncodedString()
        return """
        import Foundation
        import Testing
        import InnoRouter
        import InnoRouterTesting

        @Test("Captured InnoRouter scenario")
        @MainActor
        func \(testName)() async throws {
            let data = try #require(Data(base64Encoded: "\(encoded)"))
            let fixture = try RouterScenarioFixture<\(routeTypeName)>.decode(from: data)
            let store = \(storeFactory)(fixture.initialState)
            do {
                _ = try await RouterScenarioRunner.replay(fixture, on: store)
                store.skipReceivedEvents()
                await store.finish()
            } catch {
                store.skipReceivedEvents()
                await store.finish()
                throw error
            }
        }
        """
    }

    private static func validate<R: Route & Codable>(
        _ fixture: RouterScenarioFixture<R>,
        routeTypeName: String,
        testName: String,
        storeFactory: String
    ) throws {
        guard fixture.completeness.isComplete else {
            throw RouterScenarioSourceGenerationError.incomplete(fixture.completeness)
        }
        do {
            try RouterScenarioControlGraph.validate(fixture)
        } catch RouterScenarioReplayError.unsupportedHistoryLifetime(let step) {
            throw RouterScenarioSourceGenerationError.unsupportedHistoryLifetime(step: step)
        } catch RouterScenarioReplayError.invalidExpectedRevision(let step) {
            throw RouterScenarioSourceGenerationError.invalidExpectedRevision(step: step)
        } catch RouterScenarioReplayError.missingCancellationProvenance(let step) {
            throw RouterScenarioSourceGenerationError.missingCancellationProvenance(step: step)
        } catch {
            throw RouterScenarioSourceGenerationError.invalidEventOrdering
        }
        guard isQualifiedSwiftName(routeTypeName) else {
            throw RouterScenarioSourceGenerationError.invalidSwiftIdentifier(routeTypeName)
        }
        for identifier in [testName, storeFactory] {
            guard isQualifiedSwiftName(identifier) else {
                throw RouterScenarioSourceGenerationError.invalidSwiftIdentifier(identifier)
            }
        }
    }

    private static func isSafeFixtureFileName(_ value: String) -> Bool {
        guard value.hasSuffix(".json"), value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
        }
    }

    private static func isSwiftIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }

    private static func isQualifiedSwiftName(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { isSwiftIdentifier(String($0)) }
    }
}
