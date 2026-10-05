import Foundation

import InnoRouterCore

/// A system scene surface addressable from one macro-first route.
public enum RouterSceneStyle: String, Hashable, Sendable, Codable {
    case window
    case immersiveSpace
}

/// Stable metadata connecting a route value to a SwiftUI scene identifier.
public struct RouterSceneDescriptor<R: Route>: Hashable, Sendable, Identifiable {
    public let route: R
    public let id: String
    public let style: RouterSceneStyle

    public init(route: R, id: String, style: RouterSceneStyle) {
        self.route = route
        self.id = id
        self.style = style
    }
}

/// Type-erased scene identity used by store-level catalog validation.
package struct RouterSceneMetadata: Hashable, Sendable {
    package let id: String
    package let style: RouterSceneStyle

    package init(id: String, style: RouterSceneStyle) {
        self.id = id
        self.style = style
    }
}

/// Structural failures in an application-authored scene catalog.
public enum RouterSceneCatalogError: Error, Hashable, Sendable {
    case empty
    case emptyIdentifier
    case duplicateIdentifier(String)
    case duplicateRoute
}

/// A validated scene catalog for advanced manual conformances.
///
/// Macro-generated catalogs are checked at expansion time. Manual catalogs can
/// use this throwing value before constructing a scene driver.
public struct RouterSceneCatalog<R: RouterSceneRoute>: Sendable {
    public let descriptors: [RouterSceneDescriptor<R>]

    public init(_ descriptors: [RouterSceneDescriptor<R>]) throws {
        guard !descriptors.isEmpty else { throw RouterSceneCatalogError.empty }
        guard !descriptors.contains(where: {
            !$0.id.contains(where: { !$0.isWhitespace })
        }) else {
            throw RouterSceneCatalogError.emptyIdentifier
        }
        var identifiers: Set<String> = []
        for descriptor in descriptors where !identifiers.insert(descriptor.id).inserted {
            throw RouterSceneCatalogError.duplicateIdentifier(descriptor.id)
        }
        guard Set(descriptors.map(\.route)).count == descriptors.count else {
            throw RouterSceneCatalogError.duplicateRoute
        }
        self.descriptors = descriptors
    }

    public func descriptor(for route: R) -> RouterSceneDescriptor<R>? {
        descriptors.first { $0.route == route }
    }
}

/// A route whose `@Scene` cases form a stable window and immersive catalog.
public protocol RouterSceneRoute: Route {
    static var routerScenes: [RouterSceneDescriptor<Self>] { get }
}

public extension RouterSceneRoute {
    static func routerScene(for route: Self) -> RouterSceneDescriptor<Self>? {
        routerScenes.first { $0.route == route }
    }

    package var routerSceneMetadata: RouterSceneMetadata? {
        Self.routerScene(for: self).map {
            RouterSceneMetadata(id: $0.id, style: $0.style)
        }
    }
}

/// Side-effect milestones emitted by ``RouterSceneDriver``.
public enum RouterSceneDriverEvent<R: Route>: Sendable, Equatable {
    case openedWindow(RouterWindow<R>, sceneID: String)
    case dismissedWindow(RouterWindow<R>, sceneID: String)
    case openedImmersiveSpace(RouterImmersiveSpace<R>)
    case dismissedImmersiveSpace(RouterImmersiveSpace<R>)
    case unsupported(route: R, style: RouterSceneStyle)
    case immersiveOpenFailed(RouterImmersiveSpace<R>)
}
