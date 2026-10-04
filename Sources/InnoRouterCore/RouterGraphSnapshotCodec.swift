import Foundation

/// Opt-in, bounded flat persistence for the existing `RouterState` authority.
///
/// This codec does not replace `RouterSnapshotCodec`, install a store, apply a
/// plan, authorize routes, or create presentation-result waiters. The caller
/// must still perform current catalog/host/auth/policy admission on restoration.
/// It never writes storage, so decode or migration failure cannot overwrite the
/// original data. File adapters must also bound reads before allocation.
public struct RouterGraphSnapshotCodec<R: Route>: Sendable {
    public static var formatVersion: Int { 1 }
    public let schemaID: String
    public let schemaVersion: Int
    public let limits: RouterGraphSnapshotLimits
    package let routes: RouterGraphRouteCodec<R>
    package let legacyAdapter: RouterLegacySnapshotAdapter<R>?
    package let jsonWorkLimits: RouterJSONWorkLimits
    package let migrations: [Int: RouterGraphSnapshotMigration]

    public init(
        schemaID: String,
        schemaVersion: Int,
        routes: RouterGraphRouteCodec<R>,
        limits: RouterGraphSnapshotLimits = .provisional,
        migrations: [RouterGraphSnapshotMigration] = [],
        legacyAdapter: RouterLegacySnapshotAdapter<R>? = nil,
        maximumJSONWorkUnits: Int? = nil,
        maximumJSONKeyDecodes: Int? = nil
    ) throws {
        for (name, value) in [("maximumJSONWorkUnits", maximumJSONWorkUnits), ("maximumJSONKeyDecodes", maximumJSONKeyDecodes)] {
            if let value, value < 0 { throw RouterGraphSnapshotError.invalidLimit(name: name, value: value) }
        }
        guard !schemaID.isEmpty, schemaVersion > 0 else { throw RouterGraphSnapshotError.invalidSchema }
        var indexed: [Int: RouterGraphSnapshotMigration] = [:]
        for migration in migrations {
            guard migration.fromVersion > 0, migration.fromVersion < schemaVersion,
                  migration.toVersion == migration.fromVersion + 1 else {
                throw RouterGraphSnapshotError.invalidMigration(from: migration.fromVersion, to: migration.toVersion)
            }
            guard indexed.updateValue(migration, forKey: migration.fromVersion) == nil else {
                throw RouterGraphSnapshotError.duplicateMigration(migration.fromVersion)
            }
        }
        self.schemaID = schemaID
        self.schemaVersion = schemaVersion
        self.routes = routes
        self.limits = limits
        self.migrations = indexed
        self.legacyAdapter = legacyAdapter
        let derived = RouterJSONWorkLimits.derived(maximumBytes: limits.maximumEncodedBytes, maximumTokens: limits.maximumJSONTokens)
        self.jsonWorkLimits = .init(
            maximumWorkUnits: maximumJSONWorkUnits ?? derived.maximumWorkUnits,
            maximumKeyDecodes: maximumJSONKeyDecodes ?? derived.maximumKeyDecodes
        )
    }

    /// Stable traversal order and sorted JSON keys make repeated encoding of
    /// the same state deterministic when the app codec is deterministic. Equal route
    /// values retain distinct owned
    /// records; persisted references do not rely on randomized Swift hashing.
    public func encode(_ state: RouterState<R>) throws -> Data {
        var work = RouterJSONWorkBudget(limits: jsonWorkLimits)
        return try encode(state, work: &work)
    }

    package func encode(_ state: RouterState<R>, work: inout RouterJSONWorkBudget) throws -> Data {
        try work.withSubBudget(limits: jsonWorkLimits) { phase in
            try encodeAdmitted(state, additionalRoutes: [], work: &phase).plan
        }
    }

    /// Encodes a plan and pending-intent routes under one aggregate route budget.
    package func encodePendingGraph(
        _ state: RouterState<R>, additionalRoutes: [R], work: inout RouterJSONWorkBudget
    ) throws -> (plan: Data, payloads: [RouterGraphRoutePayload]) {
        try work.withSubBudget(limits: jsonWorkLimits) { phase in
            try encodeAdmitted(state, additionalRoutes: additionalRoutes, work: &phase)
        }
    }

    private func encodeAdmitted(
        _ state: RouterState<R>, additionalRoutes: [R], work: inout RouterJSONWorkBudget
    ) throws -> (plan: Data, payloads: [RouterGraphRoutePayload]) {
        try RouterGraphJSONPreflight.check(schemaID.utf8.count, maximum: limits.maximumEncodedBytes, name: "schemaIDBytes")
        do { try RouterResourceBudget(snapshot: limits).validate(state) }
        catch let failure {
            let field = failure.resource.hasPrefix("state.") ? String(failure.resource.dropFirst(6)) : failure.resource
            throw RouterGraphSnapshotError.limitExceeded(name: field, actual: failure.actual, maximum: failure.maximum)
        }
        var (graph, values) = try flatten(state)
        let index = try graph.validatedIndex(limits: limits)
        try graph.validateRuntimeStructure(index: index)
        let (routeCount, countOverflow) = values.count.addingReportingOverflow(additionalRoutes.count)
        guard !countOverflow else { throw RouterGraphSnapshotError.limitExceeded(name: "routes", actual: .max, maximum: limits.maximumRoutes) }
        try RouterGraphJSONPreflight.check(routeCount, maximum: limits.maximumRoutes, name: "routes")
        var total = 0
        var keyBytes = 0
        var extraPayloads: [RouterGraphRoutePayload] = []
        for (offset, route) in (values + additionalRoutes).enumerated() {
            try RouterGraphJSONPreflight.charge(1, work: &work)
            let payload = try routes.encode(route)
            try RouterGraphJSONPreflight.check(payload.data.count, maximum: limits.maximumRoutePayloadBytes, name: "routePayloadBytes")
            let (sum, overflow) = total.addingReportingOverflow(payload.data.count)
            guard !overflow else {
                throw RouterGraphSnapshotError.limitExceeded(name: "totalRoutePayloadBytes", actual: .max, maximum: limits.maximumPayloadBytes)
            }
            try RouterGraphJSONPreflight.check(sum, maximum: limits.maximumPayloadBytes, name: "totalRoutePayloadBytes")
            total = sum
            let (nextKeys, keyOverflow) = keyBytes.addingReportingOverflow(payload.stableKey.utf8.count)
            guard !keyOverflow else {
                throw RouterGraphSnapshotError.limitExceeded(name: "routeKeyBytes", actual: .max, maximum: limits.maximumPayloadBytes)
            }
            try RouterGraphJSONPreflight.check(nextKeys, maximum: limits.maximumPayloadBytes, name: "routeKeyBytes")
            keyBytes = nextKeys
            try RouterGraphJSONPreflight.charge(payload.data.count, work: &work)
            try RouterGraphJSONPreflight.charge(payload.stableKey.utf8.count, work: &work)
            if offset < values.count { graph.routes[offset].payload = payload }
            else { extraPayloads.append(payload) }
        }
        let payload = try encodeJSON(graph, work: &work)
        try preflight(payload, maximum: limits.maximumPayloadBytes, name: "payloadBytes", work: &work)
        let data = try encodeJSON(RouterGraphSnapshotEnvelope(
            formatVersion: Self.formatVersion, schemaID: schemaID,
            schemaVersion: schemaVersion, payload: payload
        ), work: &work)
        try preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", work: &work)
        return (data, extraPayloads)
    }

    /// All input and every migration output pass finite JSON, graph, ownership,
    /// and runtime-structure checks before application route decoding runs.
    /// No state is returned until every route decodes and final validation passes.
    public func decode(_ data: Data) throws -> RouterState<R> {
        var work = RouterJSONWorkBudget(limits: jsonWorkLimits)
        try preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", work: &work)
        if let legacyAdapter {
            let marker: RouterGraphFormatMarker
            try RouterGraphJSONPreflight.charge(data.count, work: &work)
            do { marker = try JSONDecoder().decode(RouterGraphFormatMarker.self, from: data) }
            catch { throw RouterGraphSnapshotError.invalidEnvelope }
            if !marker.containsGraphFormat {
                let migrated = try legacyAdapter.decode(data, limits: limits, work: &work)
                // Verify all target graph, route-key and payload limits before
                // returning state. Re-encoding is opt-in migration overhead;
                // original storage is untouched until a later admitted save.
                _ = try encode(migrated, work: &work)
                return migrated
            }
        }
        return try preparePreflightedGraphDecode(data, work: &work)()
    }

    /// Screens a nested graph between explicit outer-envelope migrations.
    /// This admits only the known library format and valid bounded structure;
    /// app schema/key migrations run once during final graph preparation.
    package func screenGraphStructure(_ data: Data, work: inout RouterJSONWorkBudget) throws {
        try work.withSubBudget(limits: jsonWorkLimits) { phase in
            try preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", work: &phase)
            try RouterGraphJSONPreflight.charge(data.count, work: &phase)
            let envelope: RouterGraphSnapshotEnvelope
            do { envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: data) }
            catch { throw RouterGraphSnapshotError.invalidEnvelope }
            guard envelope.formatVersion == Self.formatVersion else {
                throw RouterGraphSnapshotError.unsupportedFormat(snapshot: envelope.formatVersion, current: Self.formatVersion)
            }
            guard !envelope.schemaID.isEmpty, envelope.schemaVersion > 0 else { throw RouterGraphSnapshotError.invalidSchema }
            _ = try readGraph(envelope.payload, work: &phase)
        }
    }

    /// Strict flat-graph preparation. No legacy fallback or app route decoding
    /// occurs here. A composite envelope can validate every other payload before
    /// invoking the returned, already-admitted route decoding closure.
    package func prepareGraphDecode(
        _ data: Data, work: inout RouterJSONWorkBudget,
        additionalRoutePayloads: [RouterGraphRoutePayload] = []
    ) throws -> @Sendable () throws -> RouterState<R> {
        try work.withSubBudget(limits: jsonWorkLimits) { phase in
            try preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes", work: &phase)
            return try preparePreflightedGraphDecode(data, work: &phase, additionalRoutePayloads: additionalRoutePayloads)
        }
    }

    private func preparePreflightedGraphDecode(
        _ data: Data, work: inout RouterJSONWorkBudget,
        additionalRoutePayloads: [RouterGraphRoutePayload] = []
    ) throws -> @Sendable () throws -> RouterState<R> {
        let envelope: RouterGraphSnapshotEnvelope
        try RouterGraphJSONPreflight.charge(data.count, work: &work)
        do { envelope = try JSONDecoder().decode(RouterGraphSnapshotEnvelope.self, from: data) }
        catch { throw RouterGraphSnapshotError.invalidEnvelope }
        guard envelope.formatVersion == Self.formatVersion else {
            throw RouterGraphSnapshotError.unsupportedFormat(snapshot: envelope.formatVersion, current: Self.formatVersion)
        }
        guard envelope.schemaID == schemaID else { throw RouterGraphSnapshotError.schemaMismatch }
        guard envelope.schemaVersion > 0 else { throw RouterGraphSnapshotError.invalidSchema }
        guard envelope.schemaVersion <= schemaVersion else {
            throw RouterGraphSnapshotError.futureSchema(snapshot: envelope.schemaVersion, current: schemaVersion)
        }
        var payload = envelope.payload
        var version = envelope.schemaVersion
        var (graph, index) = try readGraph(payload, work: &work)
        while version < schemaVersion {
            guard let migration = migrations[version] else {
                throw RouterGraphSnapshotError.missingMigration(from: version, current: schemaVersion)
            }
            try RouterGraphJSONPreflight.charge(payload.count, work: &work)
            do { payload = try migration.transform(payload) }
            catch { throw RouterGraphSnapshotError.migrationFailed(from: version, to: migration.toVersion) }
            (graph, index) = try readGraph(payload, work: &work)
            version = migration.toVersion
        }
        // Composite pending envelopes share one route-count/payload budget.
        let (routeCount, countOverflow) = graph.routes.count.addingReportingOverflow(additionalRoutePayloads.count)
        guard !countOverflow else { throw RouterGraphSnapshotError.limitExceeded(name: "routes", actual: .max, maximum: limits.maximumRoutes) }
        try RouterGraphJSONPreflight.check(routeCount, maximum: limits.maximumRoutes, name: "routes")
        var totalBytes = 0
        var totalKeyBytes = 0
        func admit(_ payload: RouterGraphRoutePayload, work: inout RouterJSONWorkBudget) throws {
            try routes.validate(payload)
            try RouterGraphJSONPreflight.check(payload.data.count, maximum: limits.maximumRoutePayloadBytes, name: "routePayloadBytes")
            let (bytes, overflow) = totalBytes.addingReportingOverflow(payload.data.count)
            guard !overflow else { throw RouterGraphSnapshotError.limitExceeded(name: "totalRoutePayloadBytes", actual: .max, maximum: limits.maximumPayloadBytes) }
            try RouterGraphJSONPreflight.check(bytes, maximum: limits.maximumPayloadBytes, name: "totalRoutePayloadBytes")
            totalBytes = bytes
            let (keys, keyOverflow) = totalKeyBytes.addingReportingOverflow(payload.stableKey.utf8.count)
            guard !keyOverflow else { throw RouterGraphSnapshotError.limitExceeded(name: "routeKeyBytes", actual: .max, maximum: limits.maximumPayloadBytes) }
            try RouterGraphJSONPreflight.check(keys, maximum: limits.maximumPayloadBytes, name: "routeKeyBytes")
            totalKeyBytes = keys
            try RouterGraphJSONPreflight.charge(payload.data.count, work: &work)
            try RouterGraphJSONPreflight.charge(1, work: &work)
        }
        // All admission is complete before the returned closure can decode a route.
        for record in graph.routes { try admit(record.payload, work: &work) }
        for payload in additionalRoutePayloads { try admit(payload, work: &work) }
        let preparedGraph = graph
        let preparedIndex = index
        let preparedRoutes = routes
        return {
            var decoded: [String: R] = [:]
            for record in preparedGraph.routes {
                decoded[record.id] = try preparedRoutes.decode(record.payload)
            }
            do {
                return try preparedGraph.materialize(index: preparedIndex) { id in
                    guard let route = decoded[id] else { throw RouterGraphSnapshotError.invalidGraph }
                    return route
                }
            } catch let error as RouterGraphSnapshotError {
                throw error
            } catch {
                throw RouterGraphSnapshotError.invalidState
            }
        }
    }

    private func readGraph(_ payload: Data, work: inout RouterJSONWorkBudget) throws -> (RouterGraphSnapshot, RouterGraphSnapshotIndex) {
        try preflight(payload, maximum: limits.maximumPayloadBytes, name: "payloadBytes", work: &work)
        let graph: RouterGraphSnapshot
        try RouterGraphJSONPreflight.charge(payload.count, work: &work)
        do { graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: payload) }
        catch { throw RouterGraphSnapshotError.invalidGraph }
        let index = try graph.validatedIndex(limits: limits)
        try graph.validateRuntimeStructure(index: index)
        return (graph, index)
    }

    private func preflight(_ data: Data, maximum: Int, name: String, work: inout RouterJSONWorkBudget) throws {
        try RouterGraphJSONPreflight.validate(data, maximumBytes: maximum, limits: limits, byteName: name, work: &work)
    }

    private func encodeJSON(_ value: some Encodable, work: inout RouterJSONWorkBudget) throws -> Data {
        try RouterGraphJSONPreflight.charge(1, work: &work)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(value) }
        catch { throw RouterGraphSnapshotError.encodingFailed }
    }

    /// Iterative flattening checks topology budgets before application encoding
    /// or recursive runtime validation, including on oversized constructed input.
    private func flatten(_ state: RouterState<R>) throws -> (RouterGraphSnapshot, [R]) {
        try RouterGraphJSONPreflight.check(state.windows.count, maximum: limits.maximumWindows, name: "windows")
        var work: [(id: String, node: RouterNode<R>, depth: Int, presentations: Int)] = []
        var values: [R] = []
        var routeRecords: [RouterGraphRouteRecord] = []
        var nodeRecords: [RouterGraphNodeRecord] = []
        var presentationRecords: [RouterGraphPresentationRecord] = []
        func nodeID(_ node: RouterNode<R>, depth: Int = 1, presentations: Int = 0) throws -> String {
            try RouterGraphJSONPreflight.check(work.count + 1, maximum: limits.maximumNodes, name: "nodes")
            try RouterGraphJSONPreflight.check(depth, maximum: limits.maximumGraphDepth, name: "graphDepth")
            try RouterGraphJSONPreflight.check(presentations, maximum: limits.maximumPresentationDepth, name: "presentationDepth")
            let id = "n\(work.count)"
            work.append((id, node, depth, presentations))
            return id
        }
        func routeID(_ route: R) throws -> String {
            try RouterGraphJSONPreflight.check(values.count + 1, maximum: limits.maximumRoutes, name: "routes")
            let id = "r\(values.count)"
            values.append(route)
            routeRecords.append(RouterGraphRouteRecord(
                id: id, payload: .init(stableKey: "preflight-placeholder", payloadVersion: 1, data: Data())
            ))
            return id
        }
        let rootID = try nodeID(state.root)
        let windows = try state.windows.map {
            try RouterGraphWindowRecord(id: $0.id, routeID: routeID($0.route), nodeID: nodeID($0.node))
        }
        let immersive = try state.immersiveSpace.map {
            try RouterGraphImmersiveRecord(id: $0.id, routeID: routeID($0.route), nodeID: nodeID($0.node))
        }
        var cursor = 0
        while cursor < work.count {
            let entry = work[cursor]
            cursor += 1
            switch entry.node {
            case .stack(let stack):
                try RouterGraphJSONPreflight.check(stack.path.count, maximum: limits.maximumStackPath, name: "stackPath")
                let path = try stack.path.map(routeID)
                if let presentation = stack.presentation {
                    try RouterGraphJSONPreflight.check(presentationRecords.count + 1, maximum: limits.maximumPresentations, name: "presentations")
                    presentationRecords.append(try RouterGraphPresentationRecord(
                        id: presentation.id, routeID: routeID(presentation.route),
                        nodeID: nodeID(presentation.node, depth: entry.depth + 1, presentations: entry.presentations + 1),
                        style: presentation.style, options: presentation.options
                    ))
                }
                nodeRecords.append(RouterGraphNodeRecord(id: entry.id, stack: .init(routeIDs: path, presentationID: stack.presentation?.id)))
            case .container(let container):
                let branches = try container.branches.map {
                    try RouterGraphBranchRecord(scopeID: $0.id, nodeID: nodeID($0.node, depth: entry.depth + 1, presentations: entry.presentations))
                }
                let badges = container.badges.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { RouterGraphBadgeRecord(scopeID: $0.key, count: $0.value) }
                nodeRecords.append(RouterGraphNodeRecord(id: entry.id, container: .init(
                    style: container.style, selection: container.selection, branches: branches,
                    badges: badges, split: container.split
                )))
            }
        }
        return (RouterGraphSnapshot(
            rootNodeID: rootID, nodes: nodeRecords, routes: routeRecords,
            presentations: presentationRecords, windows: windows, immersiveSpace: immersive
        ), values)
    }
}

/// Presence, not a truthy/non-null value, owns graph format dispatch. Corrupt
/// graph markers never fall back to a legacy decoder, even with an adapter.
private struct RouterGraphFormatMarker: Decodable {
    let containsGraphFormat: Bool
    private enum CodingKeys: String, CodingKey { case formatVersion }
    init(from decoder: any Decoder) throws {
        containsGraphFormat = try decoder.container(keyedBy: CodingKeys.self).contains(.formatVersion)
    }
}
