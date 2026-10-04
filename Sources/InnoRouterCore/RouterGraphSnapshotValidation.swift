import Foundation

/// Structural validation never invokes an application route codec.
struct RouterGraphSnapshotIndex {
    let nodes: [String: RouterGraphNodeRecord]
    let presentations: [UUID: RouterGraphPresentationRecord]
    let postorder: [String]
}

extension RouterGraphSnapshot {
    private typealias Edge = (id: String, isPresentation: Bool)

    private struct References {
        var nodeOwners: [String: Int] = [:]
        var routeOwners: [String: Int] = [:]
        var presentationOwners: [UUID: Int] = [:]
        var edges: [String: [Edge]] = [:]
    }

    func validatedIndex(limits: RouterGraphSnapshotLimits) throws -> RouterGraphSnapshotIndex {
        try validateRecordBudgets(limits: limits)
        let nodeTable = try unique(nodes, id: \.id, kind: "node")
        let presentationTable = try unique(presentations, id: \.id, kind: "presentation")
        let routeTable = try unique(routes, id: \.id, kind: "route")
        _ = try unique(windows, id: \.id, kind: "window")
        try validateRecordValues(limits: limits)
        let references = try collectReferences(nodes: nodeTable, routes: routeTable, presentations: presentationTable)
        let postorder = try postorder(edges: references.edges)
        try validateOwnership(nodeTable.keys, counts: references.nodeOwners, kind: "node")
        try validateOwnership(routeTable.keys, counts: references.routeOwners, kind: "route")
        try validateOwnership(presentationTable.keys, counts: references.presentationOwners, kind: "presentation")
        try validateDepth(edges: references.edges, limits: limits)
        return RouterGraphSnapshotIndex(nodes: nodeTable, presentations: presentationTable, postorder: postorder)
    }

    private func unique<Value, ID: Hashable>(_ values: [Value], id: KeyPath<Value, ID>, kind: String) throws -> [ID: Value] {
        var table: [ID: Value] = [:]
        for value in values {
            guard table.updateValue(value, forKey: value[keyPath: id]) == nil else {
                throw RouterGraphSnapshotError.duplicateRecord(kind: kind)
            }
        }
        return table
    }

    private func validateRecordBudgets(limits: RouterGraphSnapshotLimits) throws {
        try RouterGraphJSONPreflight.check(nodes.count, maximum: limits.maximumNodes, name: "nodes")
        try RouterGraphJSONPreflight.check(routes.count, maximum: limits.maximumRoutes, name: "routes")
        try RouterGraphJSONPreflight.check(presentations.count, maximum: limits.maximumPresentations, name: "presentations")
        try RouterGraphJSONPreflight.check(windows.count, maximum: limits.maximumWindows, name: "windows")
        var totalPayloadBytes = 0
        for route in routes {
            try RouterGraphJSONPreflight.check(route.payload.data.count, maximum: limits.maximumRoutePayloadBytes, name: "routePayloadBytes")
            let (total, overflow) = totalPayloadBytes.addingReportingOverflow(route.payload.data.count)
            try RouterGraphJSONPreflight.check(overflow ? Int.max : total, maximum: limits.maximumPayloadBytes, name: "totalRoutePayloadBytes")
            totalPayloadBytes = total
        }
    }

    private func validateRecordValues(limits: RouterGraphSnapshotLimits) throws {
        for node in nodes {
            guard !node.id.isEmpty, (node.stack != nil) != (node.container != nil) else {
                throw RouterGraphSnapshotError.invalidGraph
            }
            if let stack = node.stack {
                try RouterGraphJSONPreflight.check(stack.routeIDs.count, maximum: limits.maximumStackPath, name: "stackPath")
            }
            if let container = node.container { try validateContainerRecord(container) }
        }
        for route in routes {
            guard !route.id.isEmpty, !route.payload.stableKey.isEmpty, route.payload.payloadVersion > 0 else {
                throw RouterGraphSnapshotError.invalidGraph
            }
        }
        if let immersiveSpace, immersiveSpace.id.isEmpty { throw RouterGraphSnapshotError.invalidGraph }
    }

    private func validateContainerRecord(_ container: RouterGraphContainerRecord) throws {
        let branchIDs = Set(container.branches.map(\.scopeID))
        guard branchIDs.count == container.branches.count,
              container.branches.allSatisfy({ !$0.scopeID.rawValue.isEmpty }),
              Set(container.badges.map(\.scopeID)).count == container.badges.count,
              container.badges.allSatisfy({ $0.count > 0 && branchIDs.contains($0.scopeID) }) else {
            throw RouterGraphSnapshotError.invalidState
        }
    }

    private func collectReferences(
        nodes: [String: RouterGraphNodeRecord], routes: [String: RouterGraphRouteRecord],
        presentations: [UUID: RouterGraphPresentationRecord]
    ) throws -> References {
        var result = References()
        func ownNode(_ id: String) throws {
            guard nodes[id] != nil else { throw RouterGraphSnapshotError.danglingReference(kind: "node") }
            result.nodeOwners[id, default: 0] += 1
        }
        func ownRoute(_ id: String) throws {
            guard routes[id] != nil else { throw RouterGraphSnapshotError.danglingReference(kind: "route") }
            result.routeOwners[id, default: 0] += 1
        }
        try ownNode(rootNodeID)
        for window in windows {
            try ownNode(window.nodeID)
            try ownRoute(window.routeID)
        }
        if let immersiveSpace {
            try ownNode(immersiveSpace.nodeID)
            try ownRoute(immersiveSpace.routeID)
        }
        for presentation in self.presentations {
            try ownRoute(presentation.routeID)
            try ownNode(presentation.nodeID)
        }
        for node in self.nodes {
            if let stack = node.stack {
                for routeID in stack.routeIDs { try ownRoute(routeID) }
                if let id = stack.presentationID {
                    guard let presentation = presentations[id] else {
                        throw RouterGraphSnapshotError.danglingReference(kind: "presentation")
                    }
                    result.presentationOwners[id, default: 0] += 1
                    result.edges[node.id, default: []].append((presentation.nodeID, true))
                }
            } else if let container = node.container {
                for branch in container.branches {
                    try ownNode(branch.nodeID)
                    result.edges[node.id, default: []].append((branch.nodeID, false))
                }
            }
        }
        return result
    }

    /// Iterative three-color DFS includes detached records, so a cycle cannot
    /// hide behind an orphan record or reach recursive runtime construction.
    private func postorder(edges: [String: [Edge]]) throws -> [String] {
        var colors: [String: Int] = [:]
        var result: [String] = []
        for node in nodes where colors[node.id] == nil {
            var work: [(String, Bool)] = [(node.id, false)]
            while let (id, exiting) = work.popLast() {
                if exiting {
                    colors[id] = 2
                    result.append(id)
                    continue
                }
                if colors[id] == 1 { throw RouterGraphSnapshotError.cycle }
                if colors[id] == 2 { continue }
                colors[id] = 1
                work.append((id, true))
                for edge in (edges[id] ?? []).reversed() { work.append((edge.id, false)) }
            }
        }
        return result
    }

    private func validateOwnership<ID: Hashable>(_ ids: some Sequence<ID>, counts: [ID: Int], kind: String) throws {
        for id in ids {
            guard counts[id] != nil else { throw RouterGraphSnapshotError.orphanRecord(kind: kind) }
            guard counts[id] == 1 else { throw RouterGraphSnapshotError.multipleOwners(kind: kind) }
        }
    }

    private func validateDepth(edges: [String: [Edge]], limits: RouterGraphSnapshotLimits) throws {
        var work = ([rootNodeID] + windows.map(\.nodeID) + [immersiveSpace?.nodeID].compactMap { $0 })
            .map { (id: $0, depth: 1, presentations: 0) }
        while let item = work.popLast() {
            try RouterGraphJSONPreflight.check(item.depth, maximum: limits.maximumGraphDepth, name: "graphDepth")
            try RouterGraphJSONPreflight.check(item.presentations, maximum: limits.maximumPresentationDepth, name: "presentationDepth")
            for edge in edges[item.id] ?? [] {
                work.append((edge.id, item.depth + 1, item.presentations + (edge.isPresentation ? 1 : 0)))
            }
        }
    }

    func materialize<R: Route>(index: RouterGraphSnapshotIndex, route: (String) throws -> R) throws -> RouterState<R> {
        var built: [String: RouterNode<R>] = [:]
        func child(_ id: String) throws -> RouterNode<R> {
            guard let node = built[id] else { throw RouterGraphSnapshotError.invalidGraph }
            return node
        }
        for id in index.postorder {
            guard let record = index.nodes[id] else { throw RouterGraphSnapshotError.invalidGraph }
            if let stack = record.stack {
                var presentation: RouterPresentation<R>?
                if let presentationID = stack.presentationID {
                    guard let entry = index.presentations[presentationID] else { throw RouterGraphSnapshotError.invalidGraph }
                    presentation = try RouterPresentation(
                        id: entry.id, route: route(entry.routeID), style: entry.style,
                        options: entry.options, node: child(entry.nodeID)
                    )
                }
                built[id] = try .stack(path: stack.routeIDs.map(route), presentation: presentation)
            } else if let container = record.container {
                built[id] = try .container(RouterContainerState(
                    style: container.style,
                    selection: container.selection,
                    branches: container.branches.map { try RouterBranch(id: $0.scopeID, node: child($0.nodeID)) },
                    badges: Dictionary(uniqueKeysWithValues: container.badges.map { ($0.scopeID, $0.count) }),
                    split: container.split
                ))
            }
        }
        let windows: [RouterWindow<R>] = try windows.map {
            try RouterWindow(id: $0.id, route: route($0.routeID), node: child($0.nodeID))
        }
        let immersive: RouterImmersiveSpace<R>? = try immersiveSpace.map {
            try RouterImmersiveSpace(id: $0.id, route: route($0.routeID), node: child($0.nodeID))
        }
        return try RouterState(root: child(rootNodeID), windows: windows, immersiveSpace: immersive)
    }

    /// Uses no application route values. Runtime layout/options validation
    /// therefore also precedes application decoding and each next migration.
    func validateRuntimeStructure(index: RouterGraphSnapshotIndex) throws {
        do {
            let _: RouterState<RouterGraphValidationRoute> = try materialize(index: index) { _ in .placeholder }
        } catch let error as RouterGraphSnapshotError {
            throw error
        } catch {
            throw RouterGraphSnapshotError.invalidState
        }
    }
}

private enum RouterGraphValidationRoute: Route { case placeholder }
