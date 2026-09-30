import Foundation
import OSLog
import SwiftUI

import InnoRouterCore

@MainActor
enum UnsupportedTabBadgeDiagnostics {
    private static let logger = Logger(
        subsystem: "io.innosquad.innorouter",
        category: "tab-presentation"
    )
    private static var hasReported = false

    static func reportIfNeeded(_ count: Int?) {
#if os(tvOS) || os(watchOS)
        guard let count, count > 0, !hasReported else { return }
        hasReported = true
        logger.warning(
            "Tab badge state is retained, but the native badge visual is unavailable on this platform."
        )
#else
        _ = count
#endif
    }
}

extension View {
    @MainActor
    @ViewBuilder
    func routerTabBadgeDiagnostics<R: Route>(
        _ count: Int?,
        scopeID: RouterScopeID,
        routerScope: RouterScope<R>
    ) -> some View {
#if os(tvOS) || os(watchOS)
        self.onChange(of: count, initial: true) { _, newCount in
            UnsupportedTabBadgeDiagnostics.reportIfNeeded(newCount)
            if let newCount, newCount > 0 {
                routerScope.reportPlatformAdaptation(
                    .tabBadgeVisualUnavailable(scope: scopeID, count: newCount)
                )
            }
        }
#else
        self
#endif
    }
}

/// Semantic native role for a macro-generated tab.
public enum RouterTabRole: String, Route, Codable {
    case standard
    case search
}

/// A stable, type-safe identity for one native tab.
///
/// `@Router` generates a nested `Tab` enum conforming to this protocol when
/// at least one route case carries `@TabItem`. Keeping tab identity separate
/// from the route enum prevents ordinary push and presentation destinations
/// from being passed to tab-only APIs.
public protocol RouterTab: Route, CaseIterable, Identifiable {
    /// Localizable label rendered alongside the icon.
    var title: LocalizedStringResource { get }
    /// SF Symbol name rendered in the tab's `Label`.
    var systemImage: String { get }
    /// Optional SF Symbol rendered while the tab is selected.
    var selectedSystemImage: String? { get }
    /// Native role used by the modern SwiftUI `Tab` surface.
    var role: RouterTabRole { get }
    /// Durable scope persisted in ``RouterState`` snapshots.
    var routerScopeID: RouterScopeID { get }
}

public extension RouterTab {
    var id: Self { self }
    var selectedSystemImage: String? { nil }
    var role: RouterTabRole { .standard }
}

/// Maps one stable tab identity to the route rendered at that tab's root.
public struct RouterTabDescriptor<R: Route, Tab: RouterTab>: Sendable, Identifiable {
    /// The generated or application-defined tab identity.
    public let tab: Tab
    /// The route rendered as the root of this tab's independent stack.
    public let root: R

    public var id: Tab { tab }

    public init(tab: Tab, root: R) {
        self.tab = tab
        self.root = root
    }
}

extension RouterTabDescriptor: Equatable where R: Equatable {}
extension RouterTabDescriptor: Hashable where R: Hashable {}

/// Structural failures in an application-authored tab catalog.
public enum RouterTabCatalogError: Error, Hashable, Sendable {
    case empty
    case duplicateTabIdentity
    case duplicateScopeID(RouterScopeID)
    case duplicateRootRoute
    case initialTabNotInCatalog
    case storeIsNotTabContainer
    case storeBranchesDoNotMatchCatalog
}

/// A validated ordered tab catalog for advanced manual conformances.
///
/// `@Router` validates this shape at expansion time. Applications that build a
/// catalog manually can construct this value with `try` and pass it to the
/// throwing ``RouterTabHost`` initializers instead of encountering a host
/// precondition.
public struct RouterTabCatalog<R: RouterTabRoute>: Sendable {
    public let descriptors: [RouterTabDescriptor<R, R.Tab>]

    public init(
        _ descriptors: [RouterTabDescriptor<R, R.Tab>]
    ) throws {
        guard !descriptors.isEmpty else { throw RouterTabCatalogError.empty }
        guard Set(descriptors.map(\.tab)).count == descriptors.count else {
            throw RouterTabCatalogError.duplicateTabIdentity
        }
        let scopeIDs = descriptors.map(\.tab.routerScopeID)
        guard Set(scopeIDs).count == scopeIDs.count else {
            let duplicate = scopeIDs.first { id in
                scopeIDs.filter { $0 == id }.count > 1
            } ?? scopeIDs[0]
            throw RouterTabCatalogError.duplicateScopeID(duplicate)
        }
        guard Set(descriptors.map(\.root)).count == descriptors.count else {
            throw RouterTabCatalogError.duplicateRootRoute
        }
        self.descriptors = descriptors
    }

    public func descriptor(for tab: R.Tab) -> RouterTabDescriptor<R, R.Tab>? {
        descriptors.first { $0.tab == tab }
    }

    public func tab(containingRoot route: R) -> R.Tab? {
        descriptors.first { $0.root == route }?.tab
    }
}

/// A route catalog containing one or more macro-first tab roots.
///
/// `@Router` supplies this conformance and a nested ``RouterTab`` identity
/// enum. Manual conformances can provide the same descriptor catalog.
public protocol RouterTabRoute: Route {
    associatedtype Tab: RouterTab

    /// The complete, ordered tab catalog rendered by ``RouterTabHost``.
    static var routerTabs: [RouterTabDescriptor<Self, Tab>] { get }
}

public extension RouterTabRoute {
    /// Returns the descriptor for a tab identity, if it is in the catalog.
    static func routerTab(for tab: Tab) -> RouterTabDescriptor<Self, Tab>? {
        routerTabs.first { $0.tab == tab }
    }

    /// Returns the tab whose root route exactly matches `route`.
    static func routerTab(containingRoot route: Self) -> Tab? {
        routerTabs.first { $0.root == route }?.tab
    }
}
