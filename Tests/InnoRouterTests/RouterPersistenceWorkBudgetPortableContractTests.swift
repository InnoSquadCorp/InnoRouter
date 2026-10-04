import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

@Suite("Persistence logical work and pre-route admission", .serialized)
struct RouterPersistenceWorkBudgetPortableContractTests {
    private enum R: Int, Route, Codable {
        case home = 1
        static let decodes = Mutex(0)
        init(from decoder: any Decoder) throws {
            Self.decodes.withLock { $0 += 1 }
            let value = try decoder.singleValueContainer().decode(Int.self)
            guard value == 1 else { throw Failure.invalid }
            self = .home
        }
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
    private enum Failure: Error { case invalid }
    private func reset() { R.decodes.withLock { $0 = 0 } }
    private var calls: Int { R.decodes.withLock { $0 } }

    private func graph(maximumWork: Int? = nil, maximumKeys: Int? = nil) throws -> RouterGraphSnapshotCodec<R> {
        let routes = try RouterGraphRouteCodec<R>(supportedPayloadVersions: ["home": 1]) { _ in
            .init(stableKey: "home", payloadVersion: 1, data: Data([1]))
        } decode: { payload in
            R.decodes.withLock { $0 += 1 }
            guard payload.data == Data([1]) else { throw Failure.invalid }
            return .home
        }
        return try .init(schemaID: "work.contract", schemaVersion: 1, routes: routes,
                         maximumJSONWorkUnits: maximumWork, maximumJSONKeyDecodes: maximumKeys)
    }

    @Test("Legacy shape budgets reject excess routes before any app decoder")
    func legacyStructureBeforeRoute() throws {
        let payload = try JSONEncoder().encode(RouterState<R>.rootStack(path: Array(repeating: .home, count: 257)))
        let data = try JSONEncoder().encode(RouterSnapshotEnvelope(schemaVersion: 17, payload: payload))
        let normal = try RouterSnapshotCodec<R>(currentVersion: 17)
        reset()
        do {
            _ = try normal.decode(data)
            Issue.record("Expected bounded shape rejection")
        } catch RouterSnapshotError.preflight(let failure) {
            #expect(failure.details.field == "state.stackPath")
            #expect(failure.details.actual == 257)
            #expect(failure.details.maximum == 256)
        }
        #expect(calls == 0)
        let expanded = try RouterSnapshotCodec<R>(currentVersion: 17, resourceBudget: .init(snapshot: .init(maximumStackPath: 257)))
        #expect(try expanded.decode(data).root == .stack(path: Array(repeating: .home, count: 257)))
        #expect(calls == 257)
        reset()
        #expect(try RouterSnapshotCodec<R>(currentVersion: 17, limits: nil).decode(data).root == .stack(path: Array(repeating: .home, count: 257)))
        #expect(calls == 257)
    }

    @Test("Zero logical work rejects legacy input before app route decoding")
    func legacyWorkAdmission() throws {
        let data = try RouterSnapshotCodec<R>(currentVersion: 1).encode(.rootStack(path: [.home]))
        let codec = try RouterSnapshotCodec<R>(currentVersion: 1, limits: .init(
            maximumEncodedByteCount: 4 * 1_024 * 1_024, maximumPayloadByteCount: 2 * 1_024 * 1_024,
            maximumJSONWorkUnits: 0
        ))
        reset()
        do { _ = try codec.decode(data); Issue.record("Expected work rejection") }
        catch RouterSnapshotError.preflight(let failure) {
            #expect(failure.details.field == "jsonWorkUnits")
            #expect(failure.details.maximum == 0)
        }
        #expect(calls == 0)
    }

    @Test("Graph work and isolated-key caps reject before route decoding", arguments: [false, true])
    func graphWorkAdmission(keyCap: Bool) throws {
        let data = try graph().encode(.rootStack(path: [.home]))
        let codec = try graph(maximumWork: keyCap ? nil : 0, maximumKeys: keyCap ? 0 : nil)
        reset()
        do { _ = try codec.decode(data); Issue.record("Expected graph admission rejection") }
        catch let failure as RouterGraphSnapshotError {
            #expect(failure.code == .limitExceeded)
            #expect(failure.details.name == (keyCap ? "jsonKeyDecodes" : "jsonWorkUnits"))
            #expect(failure.details.maximum == 0)
        }
        #expect(calls == 0)
    }

    @Test("Prepared graph decoding reserves its entire route work before invoking application code")
    func preparedExactWork() throws {
        let codec = try graph()
        let data = try codec.encode(.rootStack(path: [.home]))
        reset()
        var measured = RouterJSONWorkBudget(limits: .derived(maximumBytes: 4 * 1_024 * 1_024, maximumTokens: 262_144))
        let prepared = try codec.prepareGraphDecode(data, work: &measured)
        #expect(calls == 0)
        let used = measured.result
        #expect(used.workUnits > 0)
        #expect(try prepared() == .rootStack(path: [.home]))
        #expect(calls == 1)
        reset()
        var exact = RouterJSONWorkBudget(limits: .init(maximumWorkUnits: used.workUnits, maximumKeyDecodes: used.keyDecodes))
        let accepted = try codec.prepareGraphDecode(data, work: &exact)
        #expect(calls == 0)
        #expect(try accepted() == .rootStack(path: [.home]))
        reset()
        var limited = RouterJSONWorkBudget(limits: .init(maximumWorkUnits: used.workUnits - 1, maximumKeyDecodes: used.keyDecodes))
        #expect(throws: RouterGraphSnapshotError.self) { _ = try codec.prepareGraphDecode(data, work: &limited) }
        #expect(calls == 0)
    }

    @Test("Unknown standalone pending keys are rejected before even valid plan routes decode")
    func combinedPayloadValidation() throws {
        let codec = try graph()
        let data = try codec.encode(.rootStack(path: [.home]))
        var work = RouterJSONWorkBudget(limits: .derived(maximumBytes: 4 * 1_024 * 1_024, maximumTokens: 262_144))
        reset()
        #expect(throws: RouterGraphSnapshotError.unknownRouteKey) {
            _ = try codec.prepareGraphDecode(data, work: &work, additionalRoutePayloads: [
                .init(stableKey: "unknown", payloadVersion: 1, data: Data([1]))
            ])
        }
        #expect(calls == 0)
    }
}
