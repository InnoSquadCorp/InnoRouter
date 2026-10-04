import Foundation
import Synchronization
import Testing

@testable import InnoRouterCore

/// Every fixture in this suite is synthetic. None is a pilot-app or historical
/// persisted file, and no measured release default is inferred from these tests.
@Suite("Flat graph snapshot portable contracts")
struct RouterGraphSnapshotPortableContractTests {
    private enum Destination: Route {
        case home
        case detail(String)
    }

    private final class Calls: Sendable {
        let storage = Mutex(0)
        var count: Int { storage.withLock { $0 } }
        func hit() { storage.withLock { $0 += 1 } }
    }

    private enum FixtureFailure: Error { case secretPayload }

    private func routeCodec(encodeCalls: Calls? = nil, decodeCalls: Calls? = nil) throws -> RouterGraphRouteCodec<Destination> {
        try RouterGraphRouteCodec(supportedPayloadVersions: ["app.home": 1, "app.detail": 2]) { route in
            encodeCalls?.hit()
            switch route {
            case .home:
                return .init(stableKey: "app.home", payloadVersion: 1, data: Data())
            case .detail(let id):
                return .init(stableKey: "app.detail", payloadVersion: 2, data: Data(id.utf8))
            }
        } decode: { payload in
            decodeCalls?.hit()
            switch payload.stableKey {
            case "app.home": return .home
            case "app.detail": return .detail(String(decoding: payload.data, as: UTF8.self))
            default: throw FixtureFailure.secretPayload
            }
        }
    }

    private func codec(
        version: Int = 7,
        limits: RouterGraphSnapshotLimits = .provisional,
        migrations: [RouterGraphSnapshotMigration] = [],
        encodeCalls: Calls? = nil, decodeCalls: Calls? = nil
    ) throws -> RouterGraphSnapshotCodec<Destination> {
        try .init(
            schemaID: "synthetic.example.app", schemaVersion: version,
            routes: routeCodec(encodeCalls: encodeCalls, decodeCalls: decodeCalls),
            limits: limits, migrations: migrations
        )
    }

    private func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func data(
        _ graph: RouterGraphSnapshot,
        version: Int = 7,
        format: Int = 1,
        schemaID: String = "synthetic.example.app"
    ) throws -> Data {
        try json(RouterGraphSnapshotEnvelope(
            formatVersion: format, schemaID: schemaID,
            schemaVersion: version, payload: json(graph)
        ))
    }

    private func simpleGraph() -> RouterGraphSnapshot {
        .init(rootNodeID: "root", nodes: [.init(id: "root", stack: .init(routeIDs: ["route"]))], routes: [
            .init(id: "route", payload: .init(stableKey: "app.home", payloadVersion: 1, data: Data())),
        ])
    }

    private func rejected(_ graph: RouterGraphSnapshot, with error: RouterGraphSnapshotError) throws {
        let calls = Calls()
        let codec = try codec(decodeCalls: calls)
        let original = try data(graph)
        let copy = original
        #expect(throws: error) { try codec.decode(original) }
        #expect(original == copy)
        #expect(calls.count == 0)
    }

    @Test("Non-Codable routes round-trip stacks, tabs, split, scenes and recursive presentations deterministically")
    func completeRoundTrip() throws {
        let modalID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let nestedID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let windowID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let split = try RouterContainerState<Destination>(
            style: .split,
            branches: [
                .init(id: "sidebar", node: .stack(path: [.home])),
                .init(id: "content", node: .stack(path: [.detail("content")])),
                .init(id: "detail", node: .stack(path: [.detail("detail")], presentation: .init(
                    id: modalID, route: .detail("modal"), style: .sheet,
                    options: .init(detents: [.medium, .large], selectedDetent: .medium, cornerRadius: 8),
                    node: .stack(path: [.detail("modal-child")], presentation: .init(
                        id: nestedID, route: .home, style: .popover,
                        node: .container(try .init(style: .tabs, selection: "inside", branches: [
                            .init(id: "inside", node: .stack(path: [.detail("leaf")])),
                        ]))
                    ))
                ))),
            ], split: .init(content: "content", visibility: .doubleColumn, preferredCompactColumn: .content)
        )
        let state = try RouterState<Destination>(
            root: .container(.init(style: .tabs, selection: "main", branches: [
                .init(id: "main", node: .container(split)),
                .init(id: "settings", node: .stack(path: [.home])),
            ], badges: ["settings": 2, "main": 3])),
            windows: [.init(id: windowID, route: .detail("window"), node: .stack(path: [.home]))],
            immersiveSpace: .init(id: "studio", route: .detail("space"), node: .stack(path: [.detail("immersive")]))
        )
        let codec = try codec()
        let first = try codec.encode(state)
        #expect(first == (try codec.encode(state)))
        #expect(try codec.decode(first) == state)
        let envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: first)
        #expect(envelope.formatVersion == 1)
        #expect(envelope.schemaVersion == 7)
        let graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: envelope.payload)
        #expect(graph.presentations.count == 2)
        #expect(graph.nodes.allSatisfy { ($0.stack != nil) != ($0.container != nil) })
        let text = String(decoding: first, as: UTF8.self) + String(decoding: envelope.payload, as: UTF8.self)
        for prohibited in ["continuation", "waiter", "authorizationGeneration", "lifetimeGeneration", "incarnation", "grant"] {
            #expect(!text.contains(prohibited))
        }
    }

    @Test("Library format, application schema, stable route key and payload version fail closed before decoding")
    func independentVersions() throws {
        let calls = Calls()
        let codec = try codec(decodeCalls: calls)
        let graph = simpleGraph()
        #expect(throws: RouterGraphSnapshotError.unsupportedFormat(snapshot: 2, current: 1)) {
            try codec.decode(data(graph, format: 2))
        }
        #expect(throws: RouterGraphSnapshotError.unsupportedFormat(snapshot: 0, current: 1)) {
            try codec.decode(data(graph, format: 0))
        }
        #expect(throws: RouterGraphSnapshotError.futureSchema(snapshot: 8, current: 7)) {
            try codec.decode(data(graph, version: 8))
        }
        #expect(throws: RouterGraphSnapshotError.schemaMismatch) {
            try codec.decode(data(graph, schemaID: "another.app"))
        }
        #expect(throws: RouterGraphSnapshotError.invalidSchema) { try codec.decode(data(graph, version: 0)) }
        var unknown = graph
        unknown.routes[0].payload.stableKey = "enum.case.name.is.not.an.implicit.key"
        #expect(throws: RouterGraphSnapshotError.unknownRouteKey) { try codec.decode(data(unknown)) }
        unknown.routes[0].payload.stableKey = "app.home"
        unknown.routes[0].payload.payloadVersion = 2
        #expect(throws: RouterGraphSnapshotError.unsupportedRoutePayloadVersion) { try codec.decode(data(unknown)) }
        #expect(calls.count == 0)
    }

    @Test("Adjacent migrations use actual app schema versions and explicit stable-key rename mapping")
    func explicitMigrationChain() throws {
        var old = simpleGraph()
        old.routes[0].payload.stableKey = "previous.home"
        let first = Calls()
        let second = Calls()
        let codec = try codec(version: 9, migrations: [
            .init(from: 7, to: 8) { data in
                first.hit()
                var graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: data)
                graph.routes[0].payload.stableKey = "app.home"
                return try JSONEncoder().encode(graph)
            },
            .init(from: 8, to: 9) { data in
                second.hit()
                return data
            },
        ])
        let original = try data(old)
        let copy = original
        #expect(try codec.decode(original) == .rootStack(path: [.home]))
        #expect(first.count == 1 && second.count == 1)
        #expect(original == copy)
    }

    @Test("Migration gaps, thrown errors and oversized intermediate output preserve source bytes")
    func migrationFailures() throws {
        let original = try data(simpleGraph())
        let copy = original
        let calls = Calls()
        let missing = try codec(version: 9, migrations: [.init(from: 7, to: 8) { $0 }], decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.missingMigration(from: 8, current: 9)) { try missing.decode(original) }
        let failing = try codec(version: 8, migrations: [.init(from: 7, to: 8) { _ in throw FixtureFailure.secretPayload }], decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.migrationFailed(from: 7, to: 8)) { try failing.decode(original) }
        let nextStep = Calls()
        let oversized = try codec(version: 9, limits: .init(maximumPayloadBytes: 1_024), migrations: [
            .init(from: 7, to: 8) { _ in Data(repeating: 32, count: 1_025) },
            .init(from: 8, to: 9) { data in
                nextStep.hit()
                return data
            },
        ], decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "payloadBytes", actual: 1_025, maximum: 1_024)) {
            try oversized.decode(original)
        }
        #expect(calls.count == 0 && nextStep.count == 0)
        #expect(original == copy)
    }

    @Test("Every migration output is structurally checked before the next step")
    func intermediateGraphFailure() throws {
        let next = Calls()
        let route = Calls()
        let codec = try codec(version: 9, migrations: [
            .init(from: 7, to: 8) { data in
                var graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: data)
                graph.rootNodeID = "missing"
                return try JSONEncoder().encode(graph)
            },
            .init(from: 8, to: 9) { data in
                next.hit()
                return data
            },
        ], decodeCalls: route)
        let original = try data(simpleGraph())
        let copy = original
        #expect(throws: RouterGraphSnapshotError.danglingReference(kind: "node")) { try codec.decode(original) }
        #expect(next.count == 0 && route.count == 0 && original == copy)
    }

    @Test("Duplicate, dangling, cyclic, multiply owned and detached records are rejected")
    func invalidReferences() throws {
        var graph = simpleGraph()
        graph.nodes.append(graph.nodes[0])
        try rejected(graph, with: .duplicateRecord(kind: "node"))
        graph = simpleGraph()
        graph.routes.append(graph.routes[0])
        try rejected(graph, with: .duplicateRecord(kind: "route"))
        graph = simpleGraph()
        graph.rootNodeID = "missing"
        try rejected(graph, with: .danglingReference(kind: "node"))
        graph = simpleGraph()
        graph.nodes[0].stack?.routeIDs = ["missing"]
        try rejected(graph, with: .danglingReference(kind: "route"))
        graph = simpleGraph()
        graph.nodes[0].stack?.presentationID = UUID()
        try rejected(graph, with: .danglingReference(kind: "presentation"))
        graph = .init(rootNodeID: "root", nodes: [
            .init(id: "root", container: .init(style: .custom("cycle"), branches: [.init(scopeID: "a", nodeID: "root")])),
        ])
        try rejected(graph, with: .cycle)
        graph = .init(rootNodeID: "root", nodes: [
            .init(id: "root", container: .init(style: .custom("shared"), branches: [
                .init(scopeID: "a", nodeID: "child"), .init(scopeID: "b", nodeID: "child"),
            ])),
            .init(id: "child", stack: .init()),
        ])
        try rejected(graph, with: .multipleOwners(kind: "node"))
        graph = simpleGraph()
        graph.nodes[0].stack?.routeIDs.append("route")
        try rejected(graph, with: .multipleOwners(kind: "route"))
        graph = simpleGraph()
        graph.nodes.append(.init(id: "detached", stack: .init()))
        try rejected(graph, with: .orphanRecord(kind: "node"))
        graph = simpleGraph()
        graph.nodes[0].stack?.routeIDs = []
        try rejected(graph, with: .orphanRecord(kind: "route"))
    }

    @Test("Presentation records have exact single ownership and unique IDs")
    func presentationOwnership() throws {
        let id = UUID()
        var graph = simpleGraph()
        graph.nodes[0].stack?.presentationID = id
        graph.nodes[0].stack?.routeIDs = []
        graph.nodes.append(.init(id: "child", stack: .init()))
        graph.presentations = [.init(id: id, routeID: "route", nodeID: "child", style: .sheet)]
        #expect(try codec().decode(data(graph)).root == .stack(presentation: .init(id: id, route: .home, style: .sheet)))
        var invalid = graph
        invalid.presentations.append(invalid.presentations[0])
        try rejected(invalid, with: .duplicateRecord(kind: "presentation"))
        invalid = graph
        invalid.nodes[0].stack?.presentationID = nil
        try rejected(invalid, with: .orphanRecord(kind: "presentation"))
        invalid = graph
        invalid.nodes[0] = .init(id: "root", container: .init(style: .custom("two"), branches: [
            .init(scopeID: "left", nodeID: "left"), .init(scopeID: "right", nodeID: "right"),
        ]))
        invalid.nodes.append(contentsOf: [
            .init(id: "left", stack: .init(presentationID: id)),
            .init(id: "right", stack: .init(presentationID: id)),
        ])
        try rejected(invalid, with: .multipleOwners(kind: "presentation"))
    }

    @Test("Malformed runtime layout and options never enter app route decoding")
    func runtimeStructureFailures() throws {
        let id = UUID()
        var graph = simpleGraph()
        graph.nodes[0].stack?.routeIDs = []
        graph.nodes[0].stack?.presentationID = id
        graph.nodes.append(.init(id: "child", stack: .init()))
        graph.presentations = [.init(id: id, routeID: "route", nodeID: "child", style: .sheet, options: .init(cornerRadius: -1))]
        try rejected(graph, with: .invalidState)
        graph = .init(rootNodeID: "root", nodes: [.init(id: "root", container: .init(style: .tabs, branches: []))])
        try rejected(graph, with: .invalidState)
        graph = .init(rootNodeID: "root", nodes: [
            .init(id: "root", container: .init(style: .custom("badges"), branches: [.init(scopeID: "child", nodeID: "child")], badges: [.init(scopeID: "unknown", count: 1)])),
            .init(id: "child", stack: .init()),
        ])
        try rejected(graph, with: .invalidState)
    }

    @Test("JSON lexical bytes, tokens and nesting have inclusive limit/limit+1 semantics")
    func parserBoundaries() throws {
        let bytes = Data("[]".utf8)
        try RouterGraphJSONPreflight.validate(bytes, maximumBytes: 2, limits: .init(maximumJSONDepth: 1, maximumJSONTokens: 2), byteName: "testBytes")
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "testBytes", actual: 2, maximum: 1)) {
            try RouterGraphJSONPreflight.validate(bytes, maximumBytes: 1, limits: .provisional, byteName: "testBytes")
        }
        try RouterGraphJSONPreflight.validate(Data("[[]]".utf8), maximumBytes: 4, limits: .init(maximumJSONDepth: 2, maximumJSONTokens: 4), byteName: "testBytes")
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "jsonDepth", actual: 2, maximum: 1)) {
            try RouterGraphJSONPreflight.validate(Data("[[]]".utf8), maximumBytes: 4, limits: .init(maximumJSONDepth: 1), byteName: "testBytes")
        }
        try RouterGraphJSONPreflight.validate(Data("[0,0]".utf8), maximumBytes: 5, limits: .init(maximumJSONTokens: 5), byteName: "testBytes")
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "jsonTokens", actual: 5, maximum: 4)) {
            try RouterGraphJSONPreflight.validate(Data("[0,0]".utf8), maximumBytes: 5, limits: .init(maximumJSONTokens: 4), byteName: "testBytes")
        }
    }

    @Test("JSON grammar handles escaped punctuation, numbers, truncation and escaped duplicate keys")
    func parserGrammar() throws {
        for text in [#"{"x":"[{\\\"}]","n":-12.30e+4,"b":true,"a":[false,null,{}]}"#, "0", "[1,2,3]"] {
            try RouterGraphJSONPreflight.validate(Data(text.utf8), maximumBytes: 1_000, limits: .provisional, byteName: "testBytes")
        }
        for text in ["", "[", "{\"a\":}", "[1,]", "[01]", "[+1]", "[1.]", "[1e]", "[truefalse]", "{}{}", "{\"a\" 1}", "{\"a\":1,}", "\"bad\nstring\"", "\"\\x\"", "\"\\u00zz\""] {
            #expect(throws: RouterGraphSnapshotError.malformedJSON) {
                try RouterGraphJSONPreflight.validate(Data(text.utf8), maximumBytes: 1_000, limits: .provisional, byteName: "testBytes")
            }
        }
        #expect(throws: RouterGraphSnapshotError.duplicateJSONKey) {
            try RouterGraphJSONPreflight.validate(Data(#"{"a":1,"\u0061":2}"#.utf8), maximumBytes: 1_000, limits: .provisional, byteName: "testBytes")
        }
    }

    @Test("Both JSON layers are screened before application decoding")
    func preflightBeforeAppCodec() throws {
        let calls = Calls()
        let valid = try data(simpleGraph())
        let envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: valid)
        let exact = try codec(limits: .init(maximumEncodedBytes: valid.count, maximumPayloadBytes: envelope.payload.count), decodeCalls: calls)
        #expect(try exact.decode(valid) == .rootStack(path: [.home]))
        #expect(calls.count == 1)
        let small = try codec(limits: .init(maximumEncodedBytes: valid.count - 1), decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "encodedBytes", actual: valid.count, maximum: valid.count - 1)) { try small.decode(valid) }
        let payloadSmall = try codec(limits: .init(maximumPayloadBytes: envelope.payload.count - 1), decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "payloadBytes", actual: envelope.payload.count, maximum: envelope.payload.count - 1)) { try payloadSmall.decode(valid) }
        let depth = try codec(limits: .init(maximumJSONDepth: 1), decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "jsonDepth", actual: 2, maximum: 1)) { try depth.decode(valid) }
        let tokens = try codec(limits: .init(maximumJSONTokens: 1), decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "jsonTokens", actual: 2, maximum: 1)) { try tokens.decode(valid) }
        let deepPayload = Data((String(repeating: "[", count: 100) + String(repeating: "]", count: 100)).utf8)
        let deep = try json(RouterGraphSnapshotEnvelope(schemaID: "synthetic.example.app", schemaVersion: 7, payload: deepPayload))
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "jsonDepth", actual: 33, maximum: 32)) { try codec(decodeCalls: calls).decode(deep) }
        #expect(calls.count == 1)
    }

    @Test("Per-route payload bytes are checked at the boundary and one byte beyond before app decode")
    func routePayloadBoundary() throws {
        var graph = simpleGraph()
        graph.routes[0].payload = .init(stableKey: "app.detail", payloadVersion: 2, data: Data(repeating: 97, count: 4))
        let calls = Calls()
        let codec = try codec(limits: .init(maximumRoutePayloadBytes: 4), decodeCalls: calls)
        #expect(try codec.decode(data(graph)) == .rootStack(path: [.detail("aaaa")]))
        graph.routes[0].payload.data.append(97)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "routePayloadBytes", actual: 5, maximum: 4)) { try codec.decode(data(graph)) }
        #expect(calls.count == 1)
    }

    @Test("Topology budgets reject before application encoding and decoding")
    func topologyBudgets() throws {
        let calls = Calls()
        let twoRoutes = RouterState<Destination>.rootStack(path: [.home, .home])
        let exact = try codec(limits: .init(maximumStackPath: 2), encodeCalls: calls)
        #expect(try exact.decode(exact.encode(twoRoutes)) == twoRoutes)
        let before = calls.count
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "stackPath", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumStackPath: 1), encodeCalls: calls).encode(twoRoutes)
        }
        let tab = try RouterState<Destination>(root: .container(.init(style: .tabs, selection: "one", branches: [.init(id: "one")])) )
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "nodes", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumNodes: 1), encodeCalls: calls).encode(tab)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "graphDepth", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumGraphDepth: 1), encodeCalls: calls).encode(tab)
        }
        #expect(calls.count == before)
        let validTab = try codec().encode(tab)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "graphDepth", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumGraphDepth: 1), decodeCalls: calls).decode(validTab)
        }
        #expect(calls.count == before)
    }

    @Test("App codec errors are redacted and a partial route decode never returns state")
    func routeCodecFailures() throws {
        let calls = Calls()
        let failingRoutes = try RouterGraphRouteCodec<Destination>(supportedPayloadVersions: ["app.home": 1]) { _ in
            throw FixtureFailure.secretPayload
        } decode: { _ in
            calls.hit()
            throw FixtureFailure.secretPayload
        }
        let codec = try RouterGraphSnapshotCodec(schemaID: "synthetic.example.app", schemaVersion: 7, routes: failingRoutes)
        #expect(throws: RouterGraphSnapshotError.routeEncodingFailed) { try codec.encode(.rootStack(path: [.home])) }
        let original = try data(simpleGraph())
        let copy = original
        #expect(throws: RouterGraphSnapshotError.routeDecodingFailed) { try codec.decode(original) }
        #expect(calls.count == 1 && original == copy)
    }

    @Test("Every configured table and topology budget accepts its limit and rejects limit plus one")
    func allTopologyBoundaries() throws {
        func chain(_ count: Int, modal: Bool) throws -> RouterState<Destination> {
            var node: RouterNode<Destination> = .stack(path: [.home])
            for level in 1..<count {
                if modal {
                    node = .stack(presentation: .init(route: .home, style: .sheet, node: node))
                } else {
                    node = .container(try .init(style: .custom("chain"), branches: [.init(id: .init("level-\(level)"), node: node)]))
                }
            }
            return try RouterState(root: node)
        }
        let counts = Calls()
        let depthState = try chain(3, modal: false)
        let depthData = try codec().encode(depthState)
        #expect(try codec(limits: .init(maximumNodes: 3, maximumGraphDepth: 3)).decode(depthData) == depthState)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "nodes", actual: 3, maximum: 2)) {
            try codec(limits: .init(maximumNodes: 2), decodeCalls: counts).decode(depthData)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "graphDepth", actual: 3, maximum: 2)) {
            try codec(limits: .init(maximumGraphDepth: 2), decodeCalls: counts).decode(depthData)
        }
        let modalState = try chain(3, modal: true)
        let modalData = try codec().encode(modalState)
        #expect(try codec(limits: .init(maximumPresentations: 2, maximumPresentationDepth: 2)).decode(modalData) == modalState)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "presentations", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumPresentations: 1), decodeCalls: counts).decode(modalData)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "presentationDepth", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumPresentationDepth: 1), decodeCalls: counts).decode(modalData)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "presentations", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumPresentations: 1), encodeCalls: counts).encode(modalState)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "presentationDepth", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumPresentationDepth: 1), encodeCalls: counts).encode(modalState)
        }
        let pathState = RouterState<Destination>.rootStack(path: [.home, .home])
        let pathData = try codec().encode(pathState)
        #expect(try codec(limits: .init(maximumRoutes: 2, maximumStackPath: 2)).decode(pathData) == pathState)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "routes", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumRoutes: 1), decodeCalls: counts).decode(pathData)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "stackPath", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumStackPath: 1), decodeCalls: counts).decode(pathData)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "routes", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumRoutes: 1), encodeCalls: counts).encode(pathState)
        }
        let windows = try RouterState<Destination>(windows: [.init(route: .home), .init(route: .home)])
        let windowData = try codec().encode(windows)
        #expect(try codec(limits: .init(maximumWindows: 2)).decode(windowData) == windows)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "windows", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumWindows: 1), decodeCalls: counts).decode(windowData)
        }
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "windows", actual: 2, maximum: 1)) {
            try codec(limits: .init(maximumWindows: 1), encodeCalls: counts).encode(windows)
        }
        #expect(counts.count == 0)
    }

    @Test("Provisional byte ceilings are inclusive without claiming performance calibration")
    func provisionalByteCeilings() throws {
        let calls = Calls()
        let codec = try codec(decodeCalls: calls)
        let ordinary = try data(simpleGraph())
        var encodedBoundary = ordinary
        encodedBoundary.append(Data(repeating: 32, count: codec.limits.maximumEncodedBytes - ordinary.count))
        #expect(try codec.decode(encodedBoundary) == .rootStack(path: [.home]))
        encodedBoundary.append(32)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "encodedBytes", actual: 4 * 1024 * 1024 + 1, maximum: 4 * 1024 * 1024)) {
            try codec.decode(encodedBoundary)
        }
        var payload = try json(simpleGraph())
        payload.append(Data(repeating: 32, count: codec.limits.maximumPayloadBytes - payload.count))
        var envelope = RouterGraphSnapshotEnvelope(schemaID: "synthetic.example.app", schemaVersion: 7, payload: payload)
        #expect(try codec.decode(json(envelope)) == .rootStack(path: [.home]))
        envelope.payload.append(32)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "payloadBytes", actual: 2 * 1024 * 1024 + 1, maximum: 2 * 1024 * 1024)) {
            try codec.decode(json(envelope))
        }
        var graph = simpleGraph()
        graph.routes[0].payload.data = Data(repeating: 97, count: 64 * 1024)
        #expect(try codec.decode(data(graph)) == .rootStack(path: [.home]))
        graph.routes[0].payload.data.append(97)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "routePayloadBytes", actual: 64 * 1024 + 1, maximum: 64 * 1024)) {
            try codec.decode(data(graph))
        }
        #expect(calls.count == 3)
    }

    @Test("Migration JSON depth and token overflow stop before the next migration or app codec")
    func migrationParserBounds() throws {
        let next = Calls()
        let calls = Calls()
        let original = try data(simpleGraph())
        let deeplyNested = try codec(version: 9, migrations: [
            .init(from: 7, to: 8) { _ in Data((String(repeating: "[", count: 33) + String(repeating: "]", count: 33)).utf8) },
            .init(from: 8, to: 9) { input in
                next.hit()
                return input
            },
        ], decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "jsonDepth", actual: 33, maximum: 32)) {
            try deeplyNested.decode(original)
        }
        let tokenOverflow = try codec(version: 9, limits: .init(maximumJSONTokens: 200), migrations: [
            .init(from: 7, to: 8) { _ in Data(("[" + Array(repeating: "0", count: 101).joined(separator: ",") + "]").utf8) },
            .init(from: 8, to: 9) { input in
                next.hit()
                return input
            },
        ], decodeCalls: calls)
        #expect(throws: RouterGraphSnapshotError.limitExceeded(name: "jsonTokens", actual: 201, maximum: 200)) {
            try tokenOverflow.decode(original)
        }
        #expect(next.count == 0 && calls.count == 0)
    }

    @Test("Unknown later keys prevent any app decode and partial app failure preserves bytes")
    func completeRoutePrevalidation() throws {
        var graph = simpleGraph()
        graph.nodes[0].stack?.routeIDs.append("second")
        graph.routes.append(.init(id: "second", payload: .init(stableKey: "unknown", payloadVersion: 1, data: Data())))
        try rejected(graph, with: .unknownRouteKey)
        graph.routes[1].payload.stableKey = "app.home"
        let calls = Calls()
        let routeCodec = try RouterGraphRouteCodec<Destination>(supportedPayloadVersions: ["app.home": 1]) { _ in
            .init(stableKey: "app.home", payloadVersion: 1, data: Data())
        } decode: { _ in
            calls.hit()
            if calls.count == 2 { throw FixtureFailure.secretPayload }
            return .home
        }
        let partial = try RouterGraphSnapshotCodec(schemaID: "synthetic.example.app", schemaVersion: 7, routes: routeCodec)
        let bytes = try data(graph)
        let original = bytes
        #expect(throws: RouterGraphSnapshotError.routeDecodingFailed) { try partial.decode(bytes) }
        #expect(calls.count == 2 && bytes == original)
    }

    @Test("Detached cycles and ambiguous node kinds fail closed before recursive construction")
    func detachedCycleAndKinds() throws {
        var graph = simpleGraph()
        graph.nodes.append(.init(id: "detached", container: .init(style: .custom("cycle"), branches: [.init(scopeID: "self", nodeID: "detached")])))
        try rejected(graph, with: .cycle)
        graph = simpleGraph()
        graph.nodes[0].container = .init(style: .custom("ambiguous"), branches: [])
        try rejected(graph, with: .invalidGraph)
        graph = simpleGraph()
        graph.nodes[0].stack = nil
        try rejected(graph, with: .invalidGraph)
    }

    @Test("Generated bounded JSON fixtures and corruptions agree with Foundation syntax acceptance")
    func parserDifferentialCorpus() throws {
        var corpus = [String]()
        for value in 0..<64 {
            let text = "{\"key-\(value)\":[\(value),-\(value).25e2,true,false,null,{\"emoji\":\"🌲\",\"escaped\":\"\\\"[]{}\\\"\"}]}"
            corpus.append(text)
            corpus.append(String(text.dropLast()))
            corpus.append(text + " trailing")
            corpus.append(text.replacingOccurrences(of: "true", with: "tru"))
        }
        for text in corpus {
            let bytes = Data(text.utf8)
            let foundationAccepted = (try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])) != nil
            let preflightAccepted: Bool
            do {
                try RouterGraphJSONPreflight.validate(bytes, maximumBytes: 4_096, limits: .provisional, byteName: "testBytes")
                preflightAccepted = true
            } catch {
                preflightAccepted = false
            }
            #expect(preflightAccepted == foundationAccepted)
        }
    }

    @Test("Invalid configuration is throwing, with adjacent unique migrations required")
    func configuration() throws {
        #expect(throws: RouterGraphSnapshotError.invalidLimit(name: "nodes", value: 0)) { try RouterGraphSnapshotLimits(maximumNodes: 0) }
        #expect(throws: RouterGraphSnapshotError.invalidSchema) { try codec(version: 0) }
        #expect(throws: RouterGraphSnapshotError.invalidMigration(from: 1, to: 3)) {
            try codec(migrations: [.init(from: 1, to: 3) { $0 }])
        }
        #expect(throws: RouterGraphSnapshotError.duplicateMigration(1)) {
            try codec(migrations: [.init(from: 1, to: 2) { $0 }, .init(from: 1, to: 2) { $0 }])
        }
    }
}
