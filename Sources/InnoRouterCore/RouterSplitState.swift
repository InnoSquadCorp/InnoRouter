// MARK: - RouterSplitState.swift
// InnoRouterCore - canonical native split-view state
// Copyright © 2026 Inno Squad. All rights reserved.

/// A semantic column in a native two- or three-column split view.
public enum RouterSplitColumn: String, Hashable, Sendable, Codable {
    case sidebar
    case content
    case detail
}

/// Platform-neutral visibility translated to `NavigationSplitViewVisibility`.
public enum RouterSplitVisibility: String, Hashable, Sendable, Codable {
    case automatic
    case all
    case doubleColumn
    case detailOnly
}

/// Snapshot-safe layout and scope metadata for a split container.
public struct RouterSplitState: Hashable, Sendable, Codable {
    public var sidebar: RouterScopeID
    public var content: RouterScopeID?
    public var detail: RouterScopeID
    public var visibility: RouterSplitVisibility
    public var preferredCompactColumn: RouterSplitColumn

    public init(
        sidebar: RouterScopeID = "sidebar",
        content: RouterScopeID? = nil,
        detail: RouterScopeID = "detail",
        visibility: RouterSplitVisibility = .automatic,
        preferredCompactColumn: RouterSplitColumn = .detail
    ) throws {
        let scopeIDs = [sidebar, content, detail].compactMap { $0 }
        guard scopeIDs.allSatisfy({ !$0.rawValue.isEmpty }) else {
            throw RouterStateValidationError.emptyScope
        }
        guard Set(scopeIDs).count == scopeIDs.count else {
            throw RouterStateValidationError.duplicateSplitColumnScope
        }
        if preferredCompactColumn == .content, content == nil {
            throw RouterStateValidationError.unavailableSplitColumn(.content)
        }
        self.sidebar = sidebar
        self.content = content
        self.detail = detail
        self.visibility = visibility
        self.preferredCompactColumn = preferredCompactColumn
    }

    /// Returns the stable router scope assigned to `column`.
    public func scopeID(for column: RouterSplitColumn) -> RouterScopeID? {
        switch column {
        case .sidebar: sidebar
        case .content: content
        case .detail: detail
        }
    }

    package static var standardTwoColumn: Self {
        do {
            return try Self()
        } catch {
            preconditionFailure("The built-in two-column split layout must be valid: \(error)")
        }
    }

    package static var standardThreeColumn: Self {
        do {
            return try Self(content: "content")
        } catch {
            preconditionFailure("The built-in three-column split layout must be valid: \(error)")
        }
    }

    func validate(against branchIDs: [RouterScopeID]) throws {
        let columnScopes = supportedColumns.compactMap(scopeID(for:))
        for column in supportedColumns {
            guard let scope = scopeID(for: column), branchIDs.contains(scope) else {
                throw RouterStateValidationError.missingSplitColumn(column)
            }
        }
        if let unexpected = branchIDs.first(where: { !columnScopes.contains($0) }) {
            throw RouterStateValidationError.unexpectedSplitColumnScope(unexpected)
        }
        if preferredCompactColumn == .content, content == nil {
            throw RouterStateValidationError.unavailableSplitColumn(.content)
        }
    }

    private var supportedColumns: [RouterSplitColumn] {
        content == nil ? [.sidebar, .detail] : [.sidebar, .content, .detail]
    }
}
