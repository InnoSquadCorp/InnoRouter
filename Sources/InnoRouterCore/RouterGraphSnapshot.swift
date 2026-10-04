import Foundation

/// Finite, application-selected limits for the opt-in flat snapshot codec.
///
/// The defaults are provisional starting values, not calibrated release guarantees.
/// JSON depth counts objects/arrays (the root is depth one). JSON tokens count
/// strings, numbers, literals and every structural punctuation byte. Graph depth
/// counts nodes including the domain root; presentation depth counts modal edges.
public struct RouterGraphSnapshotLimits: Hashable, Sendable {
    public let maximumEncodedBytes: Int
    public let maximumPayloadBytes: Int
    public let maximumRoutePayloadBytes: Int
    public let maximumJSONDepth: Int
    public let maximumJSONTokens: Int
    public let maximumNodes: Int
    public let maximumRoutes: Int
    public let maximumPresentations: Int
    public let maximumGraphDepth: Int
    public let maximumStackPath: Int
    public let maximumPresentationDepth: Int
    public let maximumWindows: Int

    public init(
        maximumEncodedBytes: Int = 4 * 1024 * 1024,
        maximumPayloadBytes: Int = 2 * 1024 * 1024,
        maximumRoutePayloadBytes: Int = 64 * 1024,
        maximumJSONDepth: Int = 32,
        maximumJSONTokens: Int = 262_144,
        maximumNodes: Int = 1_024,
        maximumRoutes: Int = 8_192,
        maximumPresentations: Int = 1_024,
        maximumGraphDepth: Int = 32,
        maximumStackPath: Int = 256,
        maximumPresentationDepth: Int = 8,
        maximumWindows: Int = 32
    ) throws {
        let values = [
            "encodedBytes": maximumEncodedBytes, "payloadBytes": maximumPayloadBytes,
            "routePayloadBytes": maximumRoutePayloadBytes, "jsonDepth": maximumJSONDepth,
            "jsonTokens": maximumJSONTokens, "nodes": maximumNodes, "routes": maximumRoutes,
            "presentations": maximumPresentations, "graphDepth": maximumGraphDepth,
            "stackPath": maximumStackPath, "presentationDepth": maximumPresentationDepth,
            "windows": maximumWindows,
        ]
        for (name, value) in values where value <= 0 {
            throw RouterGraphSnapshotError.invalidLimit(name: name, value: value)
        }
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumRoutePayloadBytes = maximumRoutePayloadBytes
        self.maximumJSONDepth = maximumJSONDepth
        self.maximumJSONTokens = maximumJSONTokens
        self.maximumNodes = maximumNodes
        self.maximumRoutes = maximumRoutes
        self.maximumPresentations = maximumPresentations
        self.maximumGraphDepth = maximumGraphDepth
        self.maximumStackPath = maximumStackPath
        self.maximumPresentationDepth = maximumPresentationDepth
        self.maximumWindows = maximumWindows
    }

    /// Uncalibrated, finite starting configuration. Applications may choose
    /// larger finite values explicitly after measuring their own inputs.
    public static let provisional = try! Self()
}

/// An app-owned stable key/version and opaque payload. No enum case name is
/// inferred. Payload bytes are not necessarily JSON; the application owns them.
public struct RouterGraphRoutePayload: Codable, Hashable, Sendable {
    public var stableKey: String
    public var payloadVersion: Int
    public var data: Data

    public init(stableKey: String, payloadVersion: Int, data: Data) {
        self.stableKey = stableKey
        self.payloadVersion = payloadVersion
        self.data = data
    }
}

/// Explicit persistence opt-in; ordinary `Route` values need not be Codable.
///
/// The registry lists the exact current payload version for every stable key.
/// Unknown keys and versions fail before application decoding. Renames and old
/// payload versions must be mapped explicitly by an app-schema migration.
/// Synchronous application closures cannot be preempted by a library timeout.
public struct RouterGraphRouteCodec<R: Route>: Sendable {
    public let supportedPayloadVersions: [String: Int]
    private let encodeRoute: @Sendable (R) throws -> RouterGraphRoutePayload
    private let decodeRoute: @Sendable (RouterGraphRoutePayload) throws -> R

    public init(
        supportedPayloadVersions: [String: Int],
        encode: @escaping @Sendable (R) throws -> RouterGraphRoutePayload,
        decode: @escaping @Sendable (RouterGraphRoutePayload) throws -> R
    ) throws {
        guard !supportedPayloadVersions.isEmpty,
              supportedPayloadVersions.allSatisfy({ !$0.key.isEmpty && $0.value > 0 }) else {
            throw RouterGraphSnapshotError.invalidSchema
        }
        self.supportedPayloadVersions = supportedPayloadVersions
        encodeRoute = encode
        decodeRoute = decode
    }

    func validate(_ payload: RouterGraphRoutePayload) throws {
        guard let version = supportedPayloadVersions[payload.stableKey] else {
            throw RouterGraphSnapshotError.unknownRouteKey
        }
        guard payload.payloadVersion == version else {
            throw RouterGraphSnapshotError.unsupportedRoutePayloadVersion
        }
    }

    func encode(_ route: R) throws -> RouterGraphRoutePayload {
        let payload: RouterGraphRoutePayload
        do { payload = try encodeRoute(route) }
        catch { throw RouterGraphSnapshotError.routeEncodingFailed }
        try validate(payload)
        return payload
    }

    func decode(_ payload: RouterGraphRoutePayload) throws -> R {
        try validate(payload)
        do { return try decodeRoute(payload) }
        catch { throw RouterGraphSnapshotError.routeDecodingFailed }
    }
}

/// Library format and application schema evolve independently. `payload`
/// contains a bounded, flat `RouterGraphSnapshot` JSON document.
public struct RouterGraphSnapshotEnvelope: Codable, Hashable, Sendable {
    public var formatVersion: Int
    public var schemaID: String
    public var schemaVersion: Int
    public var payload: Data

    public init(formatVersion: Int = 1, schemaID: String, schemaVersion: Int, payload: Data) {
        self.formatVersion = formatVersion
        self.schemaID = schemaID
        self.schemaVersion = schemaVersion
        self.payload = payload
    }
}

/// A flat persistence DTO, separate from the runtime tree and its Codable shape.
/// Record references are local to this file; they are neither app declaration
/// identities nor live host/request incarnation tokens.
public struct RouterGraphSnapshot: Codable, Hashable, Sendable {
    public var rootNodeID: String
    public var nodes: [RouterGraphNodeRecord]
    public var routes: [RouterGraphRouteRecord]
    public var presentations: [RouterGraphPresentationRecord]
    public var windows: [RouterGraphWindowRecord]
    public var immersiveSpace: RouterGraphImmersiveRecord?

    public init(
        rootNodeID: String,
        nodes: [RouterGraphNodeRecord],
        routes: [RouterGraphRouteRecord] = [],
        presentations: [RouterGraphPresentationRecord] = [],
        windows: [RouterGraphWindowRecord] = [],
        immersiveSpace: RouterGraphImmersiveRecord? = nil
    ) {
        self.rootNodeID = rootNodeID
        self.nodes = nodes
        self.routes = routes
        self.presentations = presentations
        self.windows = windows
        self.immersiveSpace = immersiveSpace
    }
}

public struct RouterGraphNodeRecord: Codable, Hashable, Sendable {
    public var id: String
    public var stack: RouterGraphStackRecord?
    public var container: RouterGraphContainerRecord?

    public init(id: String, stack: RouterGraphStackRecord) {
        self.id = id
        self.stack = stack
    }

    public init(id: String, container: RouterGraphContainerRecord) {
        self.id = id
        self.container = container
    }
}

public struct RouterGraphStackRecord: Codable, Hashable, Sendable {
    public var routeIDs: [String]
    public var presentationID: UUID?

    public init(routeIDs: [String] = [], presentationID: UUID? = nil) {
        self.routeIDs = routeIDs
        self.presentationID = presentationID
    }
}

public struct RouterGraphBranchRecord: Codable, Hashable, Sendable {
    public var scopeID: RouterScopeID
    public var nodeID: String

    public init(scopeID: RouterScopeID, nodeID: String) {
        self.scopeID = scopeID
        self.nodeID = nodeID
    }
}

public struct RouterGraphBadgeRecord: Codable, Hashable, Sendable {
    public var scopeID: RouterScopeID
    public var count: Int

    public init(scopeID: RouterScopeID, count: Int) {
        self.scopeID = scopeID
        self.count = count
    }
}

public struct RouterGraphContainerRecord: Codable, Hashable, Sendable {
    public var style: RouterContainerStyle
    public var selection: RouterScopeID?
    public var branches: [RouterGraphBranchRecord]
    public var badges: [RouterGraphBadgeRecord]
    public var split: RouterSplitState?

    public init(
        style: RouterContainerStyle,
        selection: RouterScopeID? = nil,
        branches: [RouterGraphBranchRecord],
        badges: [RouterGraphBadgeRecord] = [],
        split: RouterSplitState? = nil
    ) {
        self.style = style
        self.selection = selection
        self.branches = branches
        self.badges = badges
        self.split = split
    }
}

public struct RouterGraphRouteRecord: Codable, Hashable, Sendable {
    public var id: String
    public var payload: RouterGraphRoutePayload

    public init(id: String, payload: RouterGraphRoutePayload) {
        self.id = id
        self.payload = payload
    }
}

public struct RouterGraphPresentationRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var routeID: String
    public var nodeID: String
    public var style: RouterPresentationStyle
    public var options: RouterPresentationOptions

    public init(
        id: UUID, routeID: String, nodeID: String, style: RouterPresentationStyle,
        options: RouterPresentationOptions = .init()
    ) {
        self.id = id
        self.routeID = routeID
        self.nodeID = nodeID
        self.style = style
        self.options = options
    }
}

public struct RouterGraphWindowRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var routeID: String
    public var nodeID: String

    public init(id: UUID, routeID: String, nodeID: String) {
        self.id = id
        self.routeID = routeID
        self.nodeID = nodeID
    }
}

public struct RouterGraphImmersiveRecord: Codable, Hashable, Sendable {
    public var id: String
    public var routeID: String
    public var nodeID: String

    public init(id: String, routeID: String, nodeID: String) {
        self.id = id
        self.routeID = routeID
        self.nodeID = nodeID
    }
}

/// One adjacent app-schema transform of the flat graph's JSON bytes.
/// Output is checked for bytes, JSON complexity, graph ownership, and runtime
/// structure before the next migration (or app route decoding) runs.
public struct RouterGraphSnapshotMigration: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    private let transformPayload: @Sendable (Data) throws -> Data

    public init(
        from fromVersion: Int, to toVersion: Int,
        transform: @escaping @Sendable (Data) throws -> Data
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        transformPayload = transform
    }

    func transform(_ payload: Data) throws -> Data { try transformPayload(payload) }
}
