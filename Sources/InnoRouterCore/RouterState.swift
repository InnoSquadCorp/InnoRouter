// MARK: - RouterState.swift
// InnoRouterCore - canonical InnoRouter 6 navigation state and reducer
// Copyright © 2026 Inno Squad. All rights reserved.

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

/// An ordered path from one scene-local router root to a nested scope.
public struct RouterScopePath: Hashable, Sendable, Codable,
    ExpressibleByArrayLiteral, CustomStringConvertible {
    public var domain: RouterScopeDomain
    public var components: [RouterScopeID]

    public init(
        _ components: [RouterScopeID] = [],
        domain: RouterScopeDomain = .application
    ) {
        self.domain = domain
        self.components = components
    }

    public init(arrayLiteral elements: RouterScopeID...) {
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
        RouterScopePath(components + [scope], domain: domain)
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
        return prefix + "/" + components.map(\.rawValue).joined(separator: "/")
    }
}

/// Native presentation styles owned by a stack scope.
public enum RouterPresentationStyle: String, Hashable, Sendable, Codable {
    case sheet
    case fullScreenCover
    case popover
}

/// Platform-neutral detents translated to native presentation values by hosts.
public enum RouterPresentationDetent: Hashable, Sendable, Codable {
    case medium
    case large
    case height(Double)
    case fraction(Double)
}

/// Visibility of the system drag affordance for a resizable presentation.
public enum RouterDragIndicatorVisibility: String, Hashable, Sendable, Codable {
    case automatic
    case visible
    case hidden
}

/// Compact-width adaptation requested for a popover.
public enum RouterCompactAdaptation: String, Hashable, Sendable, Codable {
    case automatic
    case sheet
    case popover
    case fullScreenCover
}

/// Interaction allowed with content behind a presented sheet.
public enum RouterPresentationBackgroundInteraction: Hashable, Sendable, Codable {
    case automatic
    case enabled
    case enabledUpThrough(RouterPresentationDetent)
    case disabled
}

/// How a resizable presentation prioritizes scrolling and resizing gestures.
public enum RouterPresentationContentInteraction: String, Hashable, Sendable, Codable {
    case automatic
    case resizes
    case scrolls
}

/// Native presentation behavior retained in snapshots and exact plans.
public struct RouterPresentationOptions: Hashable, Sendable, Codable {
    public var detents: [RouterPresentationDetent]
    public var selectedDetent: RouterPresentationDetent?
    public var dragIndicator: RouterDragIndicatorVisibility
    public var isInteractiveDismissDisabled: Bool
    public var compactAdaptation: RouterCompactAdaptation
    public var backgroundInteraction: RouterPresentationBackgroundInteraction
    public var contentInteraction: RouterPresentationContentInteraction
    public var cornerRadius: Double?

    public init(
        detents: [RouterPresentationDetent] = [],
        selectedDetent: RouterPresentationDetent? = nil,
        dragIndicator: RouterDragIndicatorVisibility = .automatic,
        isInteractiveDismissDisabled: Bool = false,
        compactAdaptation: RouterCompactAdaptation = .automatic,
        backgroundInteraction: RouterPresentationBackgroundInteraction = .automatic,
        contentInteraction: RouterPresentationContentInteraction = .automatic,
        cornerRadius: Double? = nil
    ) {
        self.detents = detents
        self.selectedDetent = selectedDetent
        self.dragIndicator = dragIndicator
        self.isInteractiveDismissDisabled = isInteractiveDismissDisabled
        self.compactAdaptation = compactAdaptation
        self.backgroundInteraction = backgroundInteraction
        self.contentInteraction = contentInteraction
        self.cornerRadius = cornerRadius
    }
}

/// One exact, identifiable route presentation.
public struct RouterPresentation<R: Route>: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var route: R
    public var style: RouterPresentationStyle
    public var options: RouterPresentationOptions

    public init(
        id: UUID = UUID(),
        route: R,
        style: RouterPresentationStyle,
        options: RouterPresentationOptions = .init()
    ) {
        self.id = id
        self.route = route
        self.style = style
        self.options = options
    }
}

extension RouterPresentation: Codable where R: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case route
        case style
        case options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        route = try container.decode(R.self, forKey: .route)
        style = try container.decode(RouterPresentationStyle.self, forKey: .style)
        options = try container.decodeIfPresent(
            RouterPresentationOptions.self,
            forKey: .options
        ) ?? .init()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(route, forKey: .route)
        try container.encode(style, forKey: .style)
        if options != .init() {
            try container.encode(options, forKey: .options)
        }
    }
}

/// Push and presentation state for one native navigation stack.
public struct RouterStackState<R: Route>: Hashable, Sendable {
    public var path: [R]
    public var presentation: RouterPresentation<R>?

    public init(
        path: [R] = [],
        presentation: RouterPresentation<R>? = nil
    ) {
        self.path = path
        self.presentation = presentation
    }
}

extension RouterStackState: Codable where R: Codable {}

/// The native layout semantics of a router container node.
public enum RouterContainerStyle: Hashable, Sendable {
    case tabs
    case split
    case custom(String)
}

extension RouterContainerStyle: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    private enum Kind: String, Codable {
        case tabs
        case split
        case custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .tabs:
            self = .tabs
        case .split:
            self = .split
        case .custom:
            self = .custom(try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tabs:
            try container.encode(Kind.tabs, forKey: .kind)
        case .split:
            try container.encode(Kind.split, forKey: .kind)
        case .custom(let name):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

/// A stable child entry in a router container.
public struct RouterBranch<R: Route>: Identifiable, Hashable, Sendable {
    public var id: RouterScopeID
    public var node: RouterNode<R>

    public init(id: RouterScopeID, node: RouterNode<R> = .stack()) {
        self.id = id
        self.node = node
    }
}

extension RouterBranch: Codable where R: Codable {}

/// Selection and ordered children for a tab, split, or custom container.
public struct RouterContainerState<R: Route>: Hashable, Sendable {
    public var style: RouterContainerStyle
    public var selection: RouterScopeID?
    public var branches: [RouterBranch<R>]
    public var badges: [RouterScopeID: Int]
    public var split: RouterSplitState?

    public init(
        style: RouterContainerStyle,
        selection: RouterScopeID? = nil,
        branches: [RouterBranch<R>],
        badges: [RouterScopeID: Int] = [:],
        split: RouterSplitState? = nil
    ) throws {
        let ids = branches.map(\.id)
        guard Set(ids).count == ids.count else {
            throw RouterStateValidationError.duplicateScope
        }
        if let selection, !ids.contains(selection) {
            throw RouterStateValidationError.missingSelection(selection)
        }
        if style == .tabs {
            guard !ids.isEmpty else {
                throw RouterStateValidationError.emptyContainer(style: style)
            }
            guard selection != nil else {
                throw RouterStateValidationError.selectionRequired(style: style)
            }
        }
        switch (style, split) {
        case (.split, .some(let split)):
            try split.validate(against: ids)
        case (.split, nil):
            throw RouterStateValidationError.missingSplitState
        case (_, .some):
            throw RouterStateValidationError.unexpectedSplitState
        default:
            break
        }
        self.style = style
        self.selection = selection
        self.branches = branches
        self.badges = badges.filter { ids.contains($0.key) && $0.value > 0 }
        self.split = split
    }
}

extension RouterContainerState: Codable where R: Codable {}

/// A compositional node in the canonical navigation tree.
public indirect enum RouterNode<R: Route>: Hashable, Sendable {
    case stack(RouterStackState<R>)
    case container(RouterContainerState<R>)

    public static func stack(
        path: [R] = [],
        presentation: RouterPresentation<R>? = nil
    ) -> RouterNode<R> {
        .stack(RouterStackState(path: path, presentation: presentation))
    }
}

extension RouterNode: Codable where R: Codable {}

/// A regular-window route and its independent navigation tree.
public struct RouterWindow<R: Route>: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var route: R
    public var node: RouterNode<R>

    public init(
        id: UUID = UUID(),
        route: R,
        node: RouterNode<R> = .stack()
    ) {
        self.id = id
        self.route = route
        self.node = node
    }
}

extension RouterWindow: Codable where R: Codable {}

/// An immersive-space route and its independent navigation tree.
public struct RouterImmersiveSpace<R: Route>: Identifiable, Hashable, Sendable {
    public var id: String
    public var route: R
    public var node: RouterNode<R>

    public init(
        id: String,
        route: R,
        node: RouterNode<R> = .stack()
    ) {
        self.id = id
        self.route = route
        self.node = node
    }
}

extension RouterImmersiveSpace: Codable where R: Codable {}

/// The single value-semantic source of truth owned by ``RouterStore``.
public struct RouterState<R: Route>: Hashable, Sendable {
    public var root: RouterNode<R>
    public var windows: [RouterWindow<R>]
    public var immersiveSpace: RouterImmersiveSpace<R>?

    public init(
        root: RouterNode<R> = .stack(),
        windows: [RouterWindow<R>] = [],
        immersiveSpace: RouterImmersiveSpace<R>? = nil
    ) throws {
        self.root = root
        self.windows = windows
        self.immersiveSpace = immersiveSpace
        try validate()
    }

    /// Validates stable identifiers and selections throughout the state tree.
    public func validate() throws {
        var presentationIDs: Set<UUID> = []
        try Self.validate(node: root, presentationIDs: &presentationIDs)
        let windowIDs = windows.map(\.id)
        guard Set(windowIDs).count == windowIDs.count else {
            throw RouterStateValidationError.duplicateWindow
        }
        for window in windows {
            try Self.validate(node: window.node, presentationIDs: &presentationIDs)
        }
        if let immersiveSpace, immersiveSpace.id.isEmpty {
            throw RouterStateValidationError.emptyImmersiveSpaceID
        }
        if let immersiveSpace {
            try Self.validate(node: immersiveSpace.node, presentationIDs: &presentationIDs)
        }
    }

    /// Returns the node at `path`, or `nil` when any component is missing or
    /// an intermediate node is not a container.
    public func node(at path: RouterScopePath) -> RouterNode<R>? {
        let domainRoot: RouterNode<R>?
        switch path.domain {
        case .application:
            domainRoot = root
        case .window(let id):
            domainRoot = windows.first(where: { $0.id == id })?.node
        case .immersiveSpace(let id):
            domainRoot = immersiveSpace.flatMap { $0.id == id ? $0.node : nil }
        }
        guard let domainRoot else { return nil }
        return Self.node(at: ArraySlice(path.components), in: domainRoot)
    }

    /// Returns the destination rendered as the root of a scene-local scope.
    public func sceneRootRoute(at path: RouterScopePath) -> R? {
        switch path.domain {
        case .application:
            return nil
        case .window(let id):
            return windows.first(where: { $0.id == id })?.route
        case .immersiveSpace(let id):
            return immersiveSpace.flatMap { $0.id == id ? $0.route : nil }
        }
    }

    private static func node(
        at components: ArraySlice<RouterScopeID>,
        in node: RouterNode<R>
    ) -> RouterNode<R>? {
        guard let first = components.first else { return node }
        guard case .container(let container) = node,
              let branch = container.branches.first(where: { $0.id == first }) else {
            return nil
        }
        return Self.node(at: components.dropFirst(), in: branch.node)
    }

    private static func validate(
        node: RouterNode<R>,
        presentationIDs: inout Set<UUID>
    ) throws {
        switch node {
        case .stack(let stack):
            try validate(
                presentation: stack.presentation,
                presentationIDs: &presentationIDs
            )
        case .container(let container):
            try validate(container: container, presentationIDs: &presentationIDs)
        }
    }

    private static func validate(
        presentation: RouterPresentation<R>?,
        presentationIDs: inout Set<UUID>
    ) throws {
        guard let presentation else { return }
        guard presentationIDs.insert(presentation.id).inserted else {
            throw RouterStateValidationError.duplicatePresentation(presentation.id)
        }
        for detent in presentation.options.detents {
            try validate(detent: detent)
        }
        if let selected = presentation.options.selectedDetent {
            try validate(detent: selected)
            guard presentation.options.detents.isEmpty
                ? selected == .large
                : presentation.options.detents.contains(selected) else {
                throw RouterStateValidationError.undeclaredSelectedDetent(selected)
            }
        }
        if case .enabledUpThrough(let detent) = presentation.options.backgroundInteraction {
            try validate(detent: detent)
            guard presentation.options.detents.contains(detent) else {
                throw RouterStateValidationError.undeclaredBackgroundInteractionDetent(detent)
            }
        }
        if let cornerRadius = presentation.options.cornerRadius,
           !cornerRadius.isFinite || cornerRadius < 0 {
            throw RouterStateValidationError.invalidPresentationCornerRadius(cornerRadius)
        }
    }

    private static func validate(detent: RouterPresentationDetent) throws {
        switch detent {
        case .medium, .large:
            return
        case .height(let value):
            guard value.isFinite, value > 0 else {
                throw RouterStateValidationError.invalidPresentationDetent(detent)
            }
        case .fraction(let value):
            guard value.isFinite, value > 0, value <= 1 else {
                throw RouterStateValidationError.invalidPresentationDetent(detent)
            }
        }
    }

    private static func validate(
        container: RouterContainerState<R>,
        presentationIDs: inout Set<UUID>
    ) throws {
        let ids = container.branches.map(\.id)
        guard Set(ids).count == ids.count else {
            throw RouterStateValidationError.duplicateScope
        }
        if let selection = container.selection, !ids.contains(selection) {
            throw RouterStateValidationError.missingSelection(selection)
        }
        if container.style == .tabs {
            guard !ids.isEmpty else {
                throw RouterStateValidationError.emptyContainer(style: container.style)
            }
            guard container.selection != nil else {
                throw RouterStateValidationError.selectionRequired(style: container.style)
            }
        }
        switch (container.style, container.split) {
        case (.split, .some(let split)):
            try split.validate(against: ids)
        case (.split, nil):
            throw RouterStateValidationError.missingSplitState
        case (_, .some):
            throw RouterStateValidationError.unexpectedSplitState
        default:
            break
        }
        for (scope, count) in container.badges {
            guard ids.contains(scope) else {
                throw RouterStateValidationError.unknownBadgeScope(scope)
            }
            guard count > 0 else {
                throw RouterStateValidationError.invalidBadgeCount(
                    scope: scope,
                    count: count
                )
            }
        }
        for branch in container.branches {
            guard !branch.id.rawValue.isEmpty else {
                throw RouterStateValidationError.emptyScope
            }
            try validate(
                node: branch.node,
                presentationIDs: &presentationIDs
            )
        }
    }
}

public extension RouterState {
    /// A valid empty root-stack state used by macro-first hosts.
    static var rootStack: RouterState<R> {
        try! RouterState()
    }

    /// Creates a valid root-stack state without exposing tree construction at
    /// ordinary call sites.
    static func rootStack(path: [R]) -> RouterState<R> {
        try! RouterState(root: .stack(path: path))
    }
}

extension RouterState: Codable where R: Codable {
    private enum CodingKeys: String, CodingKey {
        case root
        case windows
        case immersiveSpace
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(RouterNode<R>.self, forKey: .root)
        windows = try container.decode([RouterWindow<R>].self, forKey: .windows)
        immersiveSpace = try container.decodeIfPresent(
            RouterImmersiveSpace<R>.self,
            forKey: .immersiveSpace
        )
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(immersiveSpace, forKey: .immersiveSpace)
    }
}
