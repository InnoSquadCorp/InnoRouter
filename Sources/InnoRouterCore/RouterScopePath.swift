// InnoRouterCore - typed navigation scope boundaries

import Foundation

/// A stable identifier for one child scope in a router state tree.
///
/// Scope identifiers are persisted in snapshots, so applications should use
/// durable values instead of localized labels or array offsets.
public struct RouterScopeID: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// The scene-local authority selected by a router scope path.
public enum RouterScopeDomain: Hashable, Sendable, Codable {
    /// The application's primary router tree.
    case application
    /// One exact regular-window instance.
    case window(UUID)
    /// One exact immersive-space instance.
    case immersiveSpace(String)
}

/// An explicit boundary in a scene-local navigation tree.
///
/// String literals denote container branches. Presentation boundaries carry an
/// exact presentation identity and cannot collide with application scope names.
public enum RouterScopeComponent: Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible {
    case branch(RouterScopeID)
    case presentation(UUID)

    public init(stringLiteral value: String) {
        self = .branch(RouterScopeID(value))
    }

    public var description: String {
        switch self {
        case .branch(let id): id.description
        case .presentation(let id): "presentation[\(id.uuidString)]"
        }
    }
}

extension RouterScopeComponent: Codable {
    private enum CodingKeys: String, CodingKey {
        case branch
        case presentation
        case rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A scope component must name exactly one boundary"
            ))
        }
        if container.contains(.branch) {
            self = .branch(try container.decode(RouterScopeID.self, forKey: .branch))
        } else if container.contains(.presentation) {
            self = .presentation(try container.decode(UUID.self, forKey: .presentation))
        } else {
            // The pre-7.0 path stored an array of RouterScopeID values.
            self = .branch(RouterScopeID(try container.decode(String.self, forKey: .rawValue)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .branch(let id): try container.encode(id, forKey: .branch)
        case .presentation(let id): try container.encode(id, forKey: .presentation)
        }
    }
}

/// An ordered path from one scene-local router root to a nested scope.
public struct RouterScopePath: Hashable, Sendable, Codable,
    ExpressibleByArrayLiteral, CustomStringConvertible {
    public var domain: RouterScopeDomain
    public var components: [RouterScopeComponent]

    public init(
        _ components: [RouterScopeComponent] = [],
        domain: RouterScopeDomain = .application
    ) {
        self.domain = domain
        self.components = components
    }

    public init(arrayLiteral elements: RouterScopeComponent...) {
        self.domain = .application
        self.components = elements
    }

    /// The primary application router scope.
    public static let root = RouterScopePath([])

    /// The root scope owned by one exact regular window.
    public static func window(_ id: UUID) -> RouterScopePath {
        RouterScopePath(domain: .window(id))
    }

    /// The root scope owned by one exact immersive space.
    public static func immersiveSpace(_ id: String) -> RouterScopePath {
        RouterScopePath(domain: .immersiveSpace(id))
    }

    /// Returns a path extended by one child scope.
    public func appending(_ scope: RouterScopeID) -> RouterScopePath {
        RouterScopePath(components + [.branch(scope)], domain: domain)
    }

    /// Returns a path extended into one exact presentation's child node.
    public func appendingPresentation(_ id: UUID) -> RouterScopePath {
        RouterScopePath(components + [.presentation(id)], domain: domain)
    }

    public var description: String {
        let prefix: String
        switch domain {
        case .application:
            prefix = ""
        case .window(let id):
            prefix = "/window[\(id.uuidString)]"
        case .immersiveSpace(let id):
            prefix = "/immersive[\(id)]"
        }
        guard !components.isEmpty else { return prefix.isEmpty ? "/" : prefix }
        return prefix + "/" + components.map(\.description).joined(separator: "/")
    }
}
