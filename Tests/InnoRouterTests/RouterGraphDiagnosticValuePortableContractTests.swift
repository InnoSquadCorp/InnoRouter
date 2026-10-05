import Foundation
import Testing
import InnoRouterCore

@Suite("Graph diagnostic value contracts")
struct RouterGraphDiagnosticValuePortableContractTests {
    private enum R: String, Route { case home }
    private struct AppFailure: Error { let secret = "private-route-payload" }

    @Test("Unknown diagnostic codes round trip and retain an explicit fallback")
    func unknownCodeRoundTrip() throws {
        let failure = RouterGraphSnapshotError(
            code: .init(rawValue: "innorouter.snapshot.graph.future"),
            details: .init(actual: 9, maximum: 8)
        )
        let decoded = try JSONDecoder().decode(RouterGraphSnapshotError.self, from: JSONEncoder().encode(failure))
        #expect(decoded == failure)
        #expect(Set([decoded, failure]).count == 1)
        let known: Bool
        switch decoded.code {
        case .invalidGraph: known = true
        default: known = false
        }
        #expect(!known)
        #expect(decoded.description == decoded.code.rawValue)
    }

    @Test("Known constructors retain typed metadata and stable identities")
    func typedDetails() {
        let limit = RouterGraphSnapshotError.limitExceeded(name: "nodes", actual: 33, maximum: 32)
        #expect(limit.code == .limitExceeded)
        #expect(limit.details == .init(name: "nodes", actual: 33, maximum: 32))
        #expect(limit != .limitExceeded(name: "nodes", actual: 34, maximum: 32))
        #expect(RouterGraphSnapshotError.duplicateMigration(3).details.version == 3)
        #expect(RouterGraphSnapshotError.futureSchema(snapshot: 9, current: 2).details == .init(snapshot: 9, current: 2))
        #expect(RouterGraphSnapshotError.danglingReference(kind: "node").details.kind == "node")
        #expect(RouterGraphSnapshotError.invalidState.details == .init())
    }

    @Test("Application codec failures never enter default diagnostic descriptions")
    func codecFailureRedaction() throws {
        let routes = try RouterGraphRouteCodec<R>(supportedPayloadVersions: ["home": 1]) { _ in
            throw AppFailure()
        } decode: { _ in .home }
        let codec = try RouterGraphSnapshotCodec(schemaID: "consumer", schemaVersion: 1, routes: routes)
        do {
            _ = try codec.encode(.rootStack(path: [.home]))
            Issue.record("Expected the application's codec failure")
        } catch let failure as RouterGraphSnapshotError {
            #expect(failure.code == .routeEncodingFailed)
            #expect(failure.details == .init())
            #expect(!failure.description.contains("private-route-payload"))
        }
    }

    @Test("Actual validation returns the extensible value with numeric details")
    func actualValidationDetails() {
        do {
            _ = try RouterGraphSnapshotLimits(maximumNodes: -1)
            Issue.record("Negative resource limit must fail")
        } catch let failure as RouterGraphSnapshotError {
            #expect(failure.code == .invalidLimit)
            #expect(failure.details.name == "nodes")
            #expect(failure.details.value == -1)
            #expect(failure.description == "innorouter.snapshot.graph.invalidLimit")
        } catch {
            Issue.record("Unexpected error type")
        }
    }
}
