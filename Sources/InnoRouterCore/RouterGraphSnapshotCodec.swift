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
    private let routes: RouterGraphRouteCodec<R>
    private let migrations: [Int: RouterGraphSnapshotMigration]

    public init(
        schemaID: String,
        schemaVersion: Int,
        routes: RouterGraphRouteCodec<R>,
        limits: RouterGraphSnapshotLimits = .provisional,
        migrations: [RouterGraphSnapshotMigration] = []
    ) throws {
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
    }

    /// Stable traversal order and sorted JSON keys make repeated encoding of
    /// the same state deterministic when the app codec is deterministic. Equal route
    /// values retain distinct owned
    /// records; persisted references do not rely on randomized Swift hashing.
    public func encode(_ state: RouterState<R>) throws -> Data {
        var (graph, values) = try flatten(state)
        let index = try graph.validatedIndex(limits: limits)
        try graph.validateRuntimeStructure(index: index)
        var total = 0
        for (offset, route) in values.enumerated() {
            let payload = try routes.encode(route)
            try RouterGraphJSONPreflight.check(payload.data.count, maximum: limits.maximumRoutePayloadBytes, name: "routePayloadBytes")
            let (sum, overflow) = total.addingReportingOverflow(payload.data.count)
            try RouterGraphJSONPreflight.check(overflow ? Int.max : sum, maximum: limits.maximumPayloadBytes, name: "totalRoutePayloadBytes")
            total = sum
            graph.routes[offset].payload = payload
        }
        let payload = try encodeJSON(graph)
        try preflight(payload, maximum: limits.maximumPayloadBytes, name: "payloadBytes")
        let data = try encodeJSON(RouterGraphSnapshotEnvelope(
            formatVersion: Self.formatVersion, schemaID: schemaID,
            schemaVersion: schemaVersion, payload: payload
        ))
        try preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes")
        return data
    }

    /// All input and every migration output pass finite JSON, graph, ownership,
    /// and runtime-structure checks before application route decoding runs.
    /// No state is returned until every route decodes and final validation passes.
    public func decode(_ data: Data) throws -> RouterState<R> {
        try preflight(data, maximum: limits.maximumEncodedBytes, name: "encodedBytes")
        let envelope: RouterGraphSnapshotEnvelope
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
        var (graph, index) = try readGraph(payload)
        while version < schemaVersion {
            guard let migration = migrations[version] else {
                throw RouterGraphSnapshotError.missingMigration(from: version, current: schemaVersion)
            }
            do { payload = try migration.transform(payload) }
            catch { throw RouterGraphSnapshotError.migrationFailed(from: version, to: migration.toVersion) }
            (graph, index) = try readGraph(payload)
            version = migration.toVersion
        }
        // Validate all keys/versions before invoking even the first app decoder.
        for record in graph.routes { try routes.validate(record.payload) }
        var decoded: [String: R] = [:]
        for record in graph.routes { decoded[record.id] = try routes.decode(record.payload) }
        do {
            return try graph.materialize(index: index) { id in
                guard let route = decoded[id] else { throw RouterGraphSnapshotError.invalidGraph }
                return route
            }
        } catch let error as RouterGraphSnapshotError {
            throw error
        } catch {
            throw RouterGraphSnapshotError.invalidState
        }
    }

    private func readGraph(_ payload: Data) throws -> (RouterGraphSnapshot, RouterGraphSnapshotIndex) {
        try preflight(payload, maximum: limits.maximumPayloadBytes, name: "payloadBytes")
        let graph: RouterGraphSnapshot
        do { graph = try JSONDecoder().decode(RouterGraphSnapshot.self, from: payload) }
        catch { throw RouterGraphSnapshotError.invalidGraph }
        let index = try graph.validatedIndex(limits: limits)
        try graph.validateRuntimeStructure(index: index)
        return (graph, index)
    }

    private func preflight(_ data: Data, maximum: Int, name: String) throws {
        try RouterGraphJSONPreflight.validate(data, maximumBytes: maximum, limits: limits, byteName: name)
    }

    private func encodeJSON(_ value: some Encodable) throws -> Data {
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
