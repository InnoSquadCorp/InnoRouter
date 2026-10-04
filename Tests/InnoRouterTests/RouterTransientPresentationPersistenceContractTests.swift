import Foundation
import Synchronization
import Testing
@testable import InnoRouterCore

@Suite("Transient presentation persistence contracts", .serialized)
struct RouterTransientPresentationPersistenceContractTests {
    private struct Destination: Route, Codable {
        static let calls = Mutex((encode: 0, decode: 0))
        let value: Int
        init(_ value: Int) { self.value = value }
        init(from decoder: any Decoder) throws {
            Self.calls.withLock { $0.decode += 1 }
            value = try decoder.singleValueContainer().decode(Int.self)
        }
        func encode(to encoder: any Encoder) throws {
            Self.calls.withLock { $0.encode += 1 }
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    private func reset() { Destination.calls.withLock { $0 = (0, 0) } }
    private var encoded: Int { Destination.calls.withLock { $0.encode } }
    private var decoded: Int { Destination.calls.withLock { $0.decode } }
    private func transient(_ title: String = "Private title") -> RouterTransientPresentation {
        .init(content: .init(title: title, message: "Private message", actions: [.init(id: "ok", label: "Private label")]))
    }
    private func lateState(_ title: String = "Private title") throws -> RouterState<Destination> {
        try .init(root: .container(.init(style: .tabs, selection: "early", branches: [
            .init(id: "early", node: .stack(path: [Destination(1)])),
            .init(id: "late", node: .stack(path: [Destination(2)], presentationFamily: .alert(transient(title))))
        ], badges: ["late": 3])))
    }
    private func routeCodec() throws -> RouterGraphRouteCodec<Destination> {
        try .init(supportedPayloadVersions: ["route": 1], encode: { route in
            Destination.calls.withLock { $0.encode += 1 }
            return .init(stableKey: "route", payloadVersion: 1, data: Data([UInt8(route.value)]))
        }, decode: { payload in
            Destination.calls.withLock { $0.decode += 1 }
            return Destination(Int(payload.data.first ?? 0))
        })
    }
    private func graph(_ policy: RouterTransientPresentationPersistencePolicy = .reject,
                       limits: RouterGraphSnapshotLimits = .provisional) throws -> RouterGraphSnapshotCodec<Destination> {
        try .init(schemaID: "test", schemaVersion: 1, routes: routeCodec(), limits: limits, transientPresentations: policy)
    }
    private func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func legacyBytes(_ payload: String, version: Int = 1) throws -> Data {
        try json(RouterSnapshotEnvelope(schemaVersion: version, payload: Data(payload.utf8)))
    }
    private func injectedLegacy(_ marker: String, malformedFirstSibling: Bool = false) throws -> Data {
        let valid = try lateState().preparingTransientPersistence(.omit)
        var state = try #require(JSONSerialization.jsonObject(with: json(valid)) as? [String: Any])
        var root = try #require(state["root"] as? [String: Any])
        var wrapper = try #require(root["container"] as? [String: Any])
        var container = try #require(wrapper["_0"] as? [String: Any])
        var branches = try #require(container["branches"] as? [[String: Any]])
        branches[1]["node"] = ["stack": ["_0": ["path": [2], marker: NSNull()]]]
        if malformedFirstSibling { branches[0]["node"] = ["stack": ["_0": "malformed"]] }
        container["branches"] = branches
        wrapper["_0"] = container
        root["container"] = wrapper
        state["root"] = root
        return try json(RouterSnapshotEnvelope(schemaVersion: 1,
            payload: JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])))
    }
    private func injectedGraph(_ marker: String, version: Int = 1) throws -> Data {
        let dto = RouterGraphSnapshot(rootNodeID: "n", nodes: [.init(id: "n", stack: .init(routeIDs: ["r"]))], routes: [
            .init(id: "r", payload: .init(stableKey: "route", payloadVersion: 1, data: Data([1])))
        ])
        var object = try #require(JSONSerialization.jsonObject(with: json(dto)) as? [String: Any])
        var nodes = try #require(object["nodes"] as? [[String: Any]])
        var stack = try #require(nodes[0]["stack"] as? [String: Any])
        stack[marker] = NSNull()
        nodes[0]["stack"] = stack
        object["nodes"] = nodes
        return try json(RouterGraphSnapshotEnvelope(schemaID: "test", schemaVersion: version,
            payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
    }

    @Test func rejectsLateSiblingBeforeAnyApplicationEncoder() throws {
        let state = try lateState()
        reset()
        #expect(throws: RouterSnapshotError.transientPresentation(.transientPresent)) {
            try RouterSnapshotCodec<Destination>(currentVersion: 1).encode(state)
        }
        #expect(encoded == 0)
        #expect(throws: RouterGraphSnapshotError.transientPresentation(.transientPresent)) { try graph().encode(state) }
        #expect(encoded == 0)
        // Positive control proves both app encoder probes are reachable.
        _ = try RouterSnapshotCodec<Destination>(currentVersion: 1).encode(.rootStack(path: [Destination(1)]))
        _ = try graph().encode(.rootStack(path: [Destination(1)]))
        #expect(encoded == 2)
    }

    @Test func omissionPreservesNavigationDomainsAndOriginalValue() throws {
        let modal = RouterPresentation(route: Destination(3), style: .sheet,
            node: .stack(path: [Destination(4)], presentationFamily: .alert(transient())))
        let state = try RouterState(root: .stack(path: [Destination(1)], presentation: modal), windows: [
            .init(route: Destination(5), node: .stack(path: [Destination(6)], presentationFamily: .confirmationDialog(transient())))
        ], immersiveSpace: .init(id: "space", route: Destination(7), node: .stack(presentationFamily: .alert(transient()))))
        let expected = try state.preparingTransientPersistence(.omit)
        let legacy = try RouterSnapshotCodec<Destination>(currentVersion: 1, transientPresentations: .omit)
        #expect(try legacy.decode(legacy.encode(state)) == expected)
        let graph = try graph(.omit)
        #expect(try graph.decode(graph.encode(state)) == expected)
        #expect(state.root != expected.root)
        #expect(state.windows.first?.id == expected.windows.first?.id)
        #expect(state.immersiveSpace?.id == expected.immersiveSpace?.id)
        #expect(try graph.decode(graph.encode(lateState())).root == lateState().preparingTransientPersistence(.omit).root)
    }

    @Test func omissionCannotHideOversizedSourceMetadata() throws {
        let state = try lateState(String(repeating: "x", count: 256))
        let limits = try RouterGraphSnapshotLimits(maximumPayloadBytes: 128)
        reset()
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "metadataBytes", actual: 129, maximum: 128)) {
            try graph(.omit, limits: limits).encode(state)
        }
        let legacy = try RouterSnapshotCodec<Destination>(currentVersion: 1,
            resourceBudget: .init(snapshot: limits), transientPresentations: .omit)
        #expect(throws: RouterSnapshotError.self) { try legacy.encode(state) }
        #expect(encoded == 0)
    }

    @Test(arguments: ["presentationFamily", "alert", "confirmationDialog"])
    func reservedLegacyMarkersRejectBeforeDecodersWithOrWithoutLimits(_ marker: String) throws {
        let data = try injectedLegacy(marker)
        for limits in [RouterSnapshotLimits?.some(.provisional), nil] {
            reset()
            let codec = try RouterSnapshotCodec<Destination>(currentVersion: 1, limits: limits, transientPresentations: .omit)
            #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) { try codec.decode(data) }
            #expect(decoded == 0)
        }
    }

    @Test(arguments: ["presentationFamily", "alert", "confirmationDialog"])
    func reservedGraphMarkersRejectBeforeDecoder(_ marker: String) throws {
        reset()
        let data = try injectedGraph(marker)
        #expect(throws: RouterGraphSnapshotError.transientPresentation(.unsupportedRestoration)) { try graph(.omit).decode(data) }
        #expect(decoded == 0)
    }

    @Test func migrationInputAndEveryOutputAreScreened() throws {
        let initial = try RouterSnapshotCodec<Destination>(currentVersion: 1).encode(.rootStack(path: [Destination(1)]))
        let forbidden = try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: injectedLegacy("alert")).payload
        let migrated = try RouterSnapshotCodec<Destination>(currentVersion: 3, migrations: [
            .init(from: 1, to: 2, transform: { _ in forbidden }),
            .codable(from: 2, to: 3, decoding: RouterState<Destination>.self, transform: { $0 })
        ])
        reset()
        #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) { try migrated.decode(initial) }
        #expect(encoded == 0)
        #expect(decoded == 0)
        #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) { try migrated.decode(injectedLegacy("alert")) }
        #expect(decoded == 0)
    }

    @Test func typedMigrationOutputRejectsBeforeAnyNextRouteEncoding() throws {
        let state = try lateState()
        let codec = try RouterSnapshotCodec<Destination>(currentVersion: 2, migrations: [
            .codable(from: 1, to: 2, decoding: Int.self, transform: { _ in state })
        ])
        reset()
        #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) { try codec.decode(legacyBytes("1")) }
        #expect(encoded == 0)
        #expect(decoded == 0)
    }

    @Test func graphMigrationOutputRejectsBeforeRouteDecode() throws {
        let initial = try graph().encode(.rootStack(path: [Destination(1)]))
        let forbidden = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: injectedGraph("confirmationDialog")).payload
        let codec = try RouterGraphSnapshotCodec(schemaID: "test", schemaVersion: 2, routes: routeCodec(), migrations: [
            .init(from: 1, to: 2, transform: { _ in forbidden })
        ])
        reset()
        #expect(throws: RouterGraphSnapshotError.transientPresentation(.unsupportedRestoration)) { try codec.decode(initial) }
        #expect(decoded == 0)
    }

    @Test func fallbackAndLegacyTransformCannotRestoreTransientEvenWithOmit() throws {
        let state = try lateState()
        let legacy = try RouterSnapshotCodec<Destination>(currentVersion: 1, transientPresentations: .omit)
        reset()
        #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) {
            try legacy.decode(Data(), recovery: .use { _ in state })
        }
        let data = try legacy.encode(.rootStack(path: [Destination(1)]))
        let adapter = RouterLegacySnapshotAdapter(codec: legacy, transform: { _ in state })
        let target = try RouterGraphSnapshotCodec(schemaID: "test", schemaVersion: 1, routes: routeCodec(),
            legacyAdapter: adapter, transientPresentations: .omit)
        reset()
        #expect(throws: RouterGraphSnapshotError.transientPresentation(.unsupportedRestoration)) { try target.decode(data) }
        #expect(encoded == 0)
        #expect(decoded == 1) // The approved legacy input, never the transformed candidate.
    }

    @Test func policySurvivesOwnerCopiesAndNavigationWireIsUnchanged() throws {
        let state = try lateState()
        let budget = RouterResourceBudget()
        let legacy = try RouterSnapshotCodec<Destination>(currentVersion: 1, transientPresentations: .omit)
        let bounded = try legacy.boundedForGraphMigration(.provisional)
        #expect(bounded.transientPresentations == .omit)
        #expect(try legacy.constrained(to: budget).encode(state) == legacy.encode(state))
        let graph = try graph(.omit)
        #expect(try graph.constrained(to: budget).encode(state) == graph.encode(state))
        let nav: RouterState<Destination> = .rootStack(path: [Destination(8)])
        let bytes = try legacy.encode(nav)
        let envelope = try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: bytes)
        #expect(envelope.payload == (try json(nav)))
        reset()
        #expect(try legacy.decode(bytes) == nav)
        #expect(decoded == 1)
    }
    @Test func malformedEarlySiblingCannotHideTransientFromMigration() throws {
        let input = try injectedLegacy("presentationFamily", malformedFirstSibling: true)
        let migrationCalls = Mutex(0)
        let codec = try RouterSnapshotCodec<Destination>(currentVersion: 2, migrations: [
            .init(from: 1, to: 2, transform: { data in
                migrationCalls.withLock { $0 += 1 }
                return data
            })
        ])
        reset()
        #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) { try codec.decode(input) }
        #expect(migrationCalls.withLock { $0 } == 0)
        #expect(decoded == 0)
    }

    @Test func appOwnedMarkerNamesAreNotLibraryPresentationSlots() throws {
        struct AppRoute: Route, Codable { let alert: String; let presentationFamily: String }
        let state = RouterState<AppRoute>.rootStack(path: [.init(alert: "business", presentationFamily: "data")])
        let codec = try RouterSnapshotCodec<AppRoute>(currentVersion: 1)
        #expect(try codec.decode(codec.encode(state)) == state)
    }

    @Test func nilLimitsStillScreenEveryDuplicateLibrarySlot() throws {
        let data = try legacyBytes("""
        {"root":{"stack":{"_0":{"path":[1],"alert":null}}},"root":{"stack":{"_0":{"path":[2]}}},"windows":[]}
        """)
        reset()
        #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) {
            try RouterSnapshotCodec<Destination>(currentVersion: 1, limits: nil).decode(data)
        }
        #expect(decoded == 0)
    }

    @Test func semanticMarkerPassChargesIsolatedKeyDecodeLedger() throws {
        let data = try json(RouterState<Destination>.rootStack(path: [.init(1)]))
        var measured: RouterJSONWorkBudget? = .init(limits: .init(maximumWorkUnits: 100_000, maximumKeyDecodes: 1_000))
        try RouterLegacyRouteAdmission.rejectTransientMarkers(in: data, work: &measured)
        let usage = try #require(measured?.result)
        #expect(usage.keyDecodes > 0)
        var limited: RouterJSONWorkBudget? = .init(limits: .init(
            maximumWorkUnits: 100_000, maximumKeyDecodes: usage.keyDecodes - 1))
        #expect(throws: RouterJSONPreflightError.limitExceeded(name: "jsonKeyDecodes", actual: usage.keyDecodes,
                                                             maximum: usage.keyDecodes - 1)) {
            try RouterLegacyRouteAdmission.rejectTransientMarkers(in: data, work: &limited)
        }
    }

    @Test("Typed RouterPlan migration screens its state before any route decoder", arguments: [false, true])
    func typedPlanInputBeforeRouteDecoder(unbounded: Bool) throws {
        let forbidden = try JSONDecoder().decode(RouterSnapshotEnvelope.self, from: injectedLegacy("alert")).payload
        var wrapped = Data("{\"state\":".utf8)
        wrapped.append(forbidden)
        wrapped.append(Data("}".utf8))
        let data = try json(RouterSnapshotEnvelope(schemaVersion: 1, payload: wrapped))
        let codec = try RouterSnapshotCodec<Destination>(currentVersion: 2, migrations: [
            .codable(from: 1, to: 2, decoding: RouterPlan<Destination>.self) { $0.state },
        ], limits: unbounded ? nil : .provisional)
        reset()
        #expect(throws: RouterSnapshotError.transientPresentation(.unsupportedRestoration)) { try codec.decode(data) }
        #expect(decoded == 0)
        #expect(encoded == 0)
        let valid = RouterPlan(state: RouterState<Destination>.rootStack(path: [.init(1)]))
        let validData = try json(RouterSnapshotEnvelope(schemaVersion: 1, payload: json(valid)))
        reset()
        #expect(try codec.decode(validData) == valid.state)
        #expect(decoded == 2) // Historical plan decode, followed by current-state decode.
    }
}
